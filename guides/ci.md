# Load tests in CI

`mix stampede.run` exits with status 1 when a threshold fails, so a load test
can fail a build like any other test. Two more things make it useful in CI:
keeping the HTML report of every run, and comparing each change with the
branch it goes into.

## Comparing with the base branch

Timings depend on the machine, and CI machines vary from one job to the
next. Comparing a branch with numbers recorded elsewhere would mostly
measure that. Running both branches one after the other in the same job
compares them on the same machine.

A script that starts the app, waits for it, runs the load test and stops the
app again keeps the workflow short:

```sh
#!/bin/sh
# loadtest/ci.sh - runs the load test against a fresh server, writing the
# results to the file given first, with any other options given to the task.
set -e

out=$1
shift

mix deps.get
mix ecto.migrate
mix phx.server > server.log 2>&1 &
server=$!
trap 'kill $server' EXIT

until curl -sf -o /dev/null http://localhost:4000/; do sleep 1; done
mix stampede.run loadtest/checkout.exs --out "$out" "$@"
```

Then, in `.github/workflows/load.yml`:

```yaml
name: Load test

on:
  pull_request:

jobs:
  load:
    runs-on: ubuntu-24.04

    # To comment on the pull request with the comparison.
    permissions:
      contents: read
      pull-requests: write

    services:
      postgres:
        image: postgres:17
        env:
          POSTGRES_PASSWORD: postgres
        ports: ["5432:5432"]
        options: >-
          --health-cmd pg_isready --health-interval 5s
          --health-timeout 5s --health-retries 10

    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0

      - uses: erlef/setup-beam@v1
        with:
          elixir-version: "1.19"
          otp-version: "28"

      - run: mix deps.get && mix ecto.create

      # A threshold that already fails on the base branch should not stop
      # the comparison.
      - name: Load test the base branch
        run: |
          git checkout ${{ github.event.pull_request.base.sha }}
          sh loadtest/ci.sh base.json || true

      - name: Load test this branch
        run: |
          git checkout ${{ github.event.pull_request.head.sha }}
          sh loadtest/ci.sh head.json --html report.html

      - name: Compare with the base branch
        if: hashFiles('base.json') != ''
        run: mix stampede.compare base.json head.json --max-regression 20 --format markdown > comparison.md

      - name: Comment on the pull request
        if: always() && hashFiles('comparison.md') != ''
        run: gh pr comment ${{ github.event.pull_request.number }} --body-file comparison.md
        env:
          GH_TOKEN: ${{ github.token }}

      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: load-test-report
          path: report.html
```

The job fails when a threshold fails on the branch, or when a p50, p95 or
p99 got more than 20% slower than on the base branch. Either way, the
comparison shows up as a comment on the pull request, with the slower
percentiles in bold, and the report is kept with the run, to see where the
time went. Pull requests from forks get a read-only token, so there the
comment step fails and the comparison is only in the job's log.

## Keeping the numbers steady

  * Run for a minute or more. Short runs are mostly the first requests,
    which are slower while the server warms up.
  * Keep the load modest. The app and the load test share the CI machine,
    so a load test that takes all of its CPU slows down the app it measures.
  * Leave room in `--max-regression`. Even on one machine, timings move a
    few percent from one run to the next with no change to the code. 20% is
    a forgiving place to start; tighten it once you know how much your runs
    vary.
  * The script runs the app in the `dev` environment, which is slower than
    `prod` but slower on both branches alike. Run it with `MIX_ENV=prod`
    when your CI can build a release-like environment, to get numbers
    closer to production.

## With ExUnit

Load tests written with `Stampede.ExUnit` fail the build the same way. Run
them with `mix test --only load` while the script's server is up. The server
still runs on its own, so the load tests measure the app rather than the
test sandbox, and the test environment needs its database, as for your other
tests. `mix stampede.compare` reads the files that `mix stampede.run --out`
writes, so keep `mix stampede.run` for comparing branches.

## The first load test

The first pull request that adds a load test has nothing to compare with,
since the base branch doesn't have it yet. No `base.json` is written then,
and the comparison is skipped. Likewise, `mix stampede.compare` skips the
scenarios that only one of the files has.
