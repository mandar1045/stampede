# Contributing to Stampede

Thanks for taking the time! Bug reports, ideas, docs fixes and code are all
welcome, and you don't need to have contributed to anything before. If
you're not sure where to start, look for issues labeled
`good first issue`, or just ask in
[Discussions](https://github.com/mandar1045/stampede/discussions).

## Reporting a bug

The issue form asks for the essentials:

  * the versions of Stampede, Elixir and Erlang/OTP, and of Phoenix and
    LiveView if they're involved
  * the scenario, or the smallest one that shows the problem
  * what you expected, what happened instead, and the output of
    `mix stampede.run`

A short scenario that reproduces it is worth more than a long description.

## Getting set up

You'll need Elixir 1.18 or newer. Then:

```console
$ git clone https://github.com/mandar1045/stampede.git
$ cd stampede
$ mix deps.get
$ mix test
```

The tests start a small Phoenix app, in `test/support`, with channels,
LiveViews and uploads, and run real load tests against it. That's why the
suite takes about ten seconds instead of one. The tests tagged
`:distributed` start a second node, which needs `epmd`. `mix test` starts
it for you, and skips those tests if it can't.

A quick map of the code:

  * `lib/stampede/runner.ex` and `lib/stampede/runner/driver.ex` start and
    stop the VUs and collect what they measure
  * `lib/stampede/metrics.ex` records timings, counters and checks
  * `lib/stampede/channels`, `live_view.ex`, `http.ex` and `web_socket` are
    the clients
  * `lib/stampede/reporter` and `dashboard.ex` show the results
  * `lib/mix/tasks` has the Mix tasks

## Sending a pull request

  * Add a test for your change. A test that runs a scenario against the
    test app is the best proof that it works end to end.
  * Run `mix format` and `mix compile --warnings-as-errors`.
  * Document new options and functions, and add a line to `CHANGELOG.md`.
  * Keep each pull request to one change, so it's quick to review.

For anything big, like a new client or protocol, open an issue or a
discussion first so we can agree on the approach before you put time into
it.
