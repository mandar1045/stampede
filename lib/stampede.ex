defmodule Stampede do
  @moduledoc """
  Load testing for Elixir and Phoenix applications.

  A load test is a module that implements `Stampede.Scenario`. Stampede starts
  virtual users (VUs), each one a process that calls the scenario's
  `c:Stampede.Scenario.run/1` over and over, moves the number of running VUs
  through the stages you configured, and records how long things take.

      defmodule MyApp.Load.Lobby do
        use Stampede.Scenario

        @impl true
        def options do
          [
            stages: [{[second: 30], 1_000}, {[minute: 1], 1_000}, {[second: 10], 0}],
            thresholds: [{"channel.join", p95: 250}, {"iteration.errors", count: 0}]
          ]
        end

        @impl true
        def run(_vu) do
          {:ok, socket} = Stampede.Channels.connect("ws://localhost:4000/socket")
          {:ok, _reply} = Stampede.Channels.join(socket, "room:lobby")
          {:ok, _reply} = Stampede.Channels.push(socket, "room:lobby", "ping")
          Process.sleep(1_000)
        end
      end

  Run it with `mix stampede.run`, or from code:

      result = Stampede.run(MyApp.Load.Lobby)
      IO.puts(Stampede.Reporter.format(result))

  ## Metrics

  Every metric has a name and is a timing, a counter or a check. Stampede
  records these on its own:

    * `"iteration"` - how long each successful `c:Stampede.Scenario.run/1` took
    * `"iteration.errors"` - iterations that raised, threw or exited
    * `"iterations.dropped"` - iterations a `:rate` run could not start
      because all of its `:max_vus` were busy
    * `"vu.crashes"` - VUs that crashed and had to be replaced
    * the request metrics listed in `Stampede.HTTP`
    * the connection and channel metrics listed in `Stampede.Channels`
    * the page, join and event metrics listed in `Stampede.LiveView`
    * the connection and message metrics listed in `Stampede.WebSocket`

  Record your own with `measure/2`, `record/3`, `increment/2` and `check/2`.
  Timings, counters and checks share one set of names.

  Timings are counted in buckets that grow by 2% each, so every percentile
  in a `Stampede.Result` is within 1% of the exact value, however many samples
  the run collected.

  ## Telemetry

  Stampede emits these `:telemetry` events:

    * `[:stampede, :run, :start]` - with the `:system_time` as measurement,
      and the `:scenario` and its `:options` as metadata
    * `[:stampede, :run, :interval]` - every second, with the number of busy
      `:vus` as measurement, and the `:scenario` and the `:interval`, a point
      of `Stampede.Result`'s timeline, as metadata
    * `[:stampede, :run, :stop]` - with the `:duration` as measurement, and
      the `:scenario` and its `:result` as metadata
    * `[:stampede, :timing]` - for every timing recorded, with its
      `:duration` as measurement and its `:name` as metadata
    * `[:stampede, :counter]` - for every counter incremented, with the
      `:count` added as measurement and its `:name` as metadata
    * `[:stampede, :check]` - for every check, with a `:count` of 1 as
      measurement, and its `:name` and whether it `:passed?` as metadata

  Durations are in native time units, as usual for telemetry. The run events
  are emitted on the node that called `run/2` or `run_parallel/2`, the others
  on the node that recorded them.
  """

  alias Stampede.Metrics

  @doc """
  Runs `scenario` and returns a `Stampede.Result`.

  Options given here take precedence over the ones returned by the
  scenario's `c:Stampede.Scenario.options/0`.

  ## Options

    * `:stages` - a list of `{duration, target}` tuples. Each stage moves the
      number of running VUs in a straight line from the previous target,
      starting at zero, to `target` over `duration`. A stage with no duration
      jumps to its target right away.

    * `:vus` and `:duration` - run a constant number of VUs, 1 by default,
      for `duration` instead of going through stages. `vus: 100, duration:
      [minute: 1]` is the same as `stages: [{0, 100}, {[minute: 1], 100}]`.

    * `:rate` and `:duration` - start `rate` iterations per second for
      `duration`, however long they take, instead of keeping a number of VUs
      busy. Unlike VUs that wait for their last iteration to finish, a rate
      keeps the pressure on a server that slows down, which is how real
      traffic behaves. Rates can be fractions, such as `0.5`.

    * `:rate_stages` - like `:stages`, but each target is a rate.

    * `:max_vus` - how many iterations a `:rate` run may have in progress at
      once. VUs are started as needed and reused once they finish an
      iteration. When all of them are busy, iterations are dropped and counted
      as `"iterations.dropped"`. Defaults to `1_000`.

    * `:graceful_stop` - how long a VU that is no longer needed, because
      of a ramp down or the end of the run, may take to finish its current
      iteration. Iterations that finish in time are recorded, while the rest
      are stopped. Defaults to `0`, stopping them at once, so a VU that loops
      forever does not hold up the run.

    * `:thresholds` - a list of `{metric, limits}` tuples, such as
      `{"channel.join", p95: 250, max: 1_000}`. Each limit is the highest
      value the statistic may have for the run to pass. Timings have `:min`,
      `:mean`, `:p50`, `:p90`, `:p95`, `:p99` and `:max`, in milliseconds.
      Checks have `:failed` and `:failed_rate`, from 0 to 1. Every metric has
      `:count` and `:rate`, per second. Thresholds on a timing with no samples
      fail, while counters and checks with no samples are zero.

    * `:nodes` - the nodes to run the VUs on, `[node()]` by default. VUs and
      rates are split evenly between them, and their metrics are merged.
      Every node must be connected and able to run Stampede and the
      scenario's code, for example because it was started from the same
      project. A scenario compiled to a `.beam` file is loaded on the nodes
      that miss it.

    * `:progress` - prints the number of VUs, iterations and errors every
      second. Defaults to `false`.

  Durations are milliseconds or anything else `Kernel.to_timeout/1` accepts,
  such as `[second: 30]` or `Duration.new!(minute: 1)`.
  """
  @spec run(module(), keyword()) :: Stampede.Result.t()
  defdelegate run(scenario, opts \\ []), to: Stampede.Runner

  @doc """
  Runs several scenarios at the same time, and returns their results in the
  same order.

  Real traffic mixes kinds of users, such as many people reading a page while
  a few post to it. Each scenario runs with its own options, thresholds and
  setup, as with `run/2`, so each kind of user can have its own number of
  VUs or rate:

      [reading, posting] = Stampede.run_parallel([MyApp.Load.Reading, MyApp.Load.Posting])

  `opts` apply to every scenario and take precedence over their own options.
  Every scenario's options are checked, and its `c:Stampede.Scenario.setup/1`
  called, before any VU starts. With `progress: true`, each progress line
  names its scenario.
  """
  @spec run_parallel([module()], keyword()) :: [Stampede.Result.t()]
  defdelegate run_parallel(scenarios, opts \\ []), to: Stampede.Runner

  @doc """
  Calls `fun` and records how long it took as the timing `name`.

  Returns what `fun` returns. Nothing is recorded if `fun` raises, or when it
  is called outside of a run.

      Stampede.measure("checkout", fn -> MyApp.Client.checkout(cart) end)
  """
  @spec measure(String.t(), (-> result)) :: result when result: var
  def measure(name, fun) when is_binary(name) and is_function(fun, 0) do
    started_at = System.monotonic_time()
    result = fun.()
    Metrics.record_since(Metrics.current(), name, started_at)
    result
  end

  @doc """
  Records `duration`, given in `unit`, as the timing `name`.

  Useful when the duration comes from somewhere else, such as a timestamp
  sent back by the server.
  """
  @spec record(String.t(), non_neg_integer(), System.time_unit()) :: :ok
  def record(name, duration, unit \\ :millisecond)
      when is_binary(name) and is_integer(duration) and duration >= 0 do
    Metrics.record(Metrics.current(), name, System.convert_time_unit(duration, unit, :native))
  end

  @doc """
  Adds `amount` to the counter `name`.
  """
  @spec increment(String.t(), pos_integer()) :: :ok
  def increment(name, amount \\ 1) when is_binary(name) and is_integer(amount) and amount > 0 do
    Metrics.increment(Metrics.current(), name, amount)
  end

  @doc """
  Records whether `condition` holds as the check `name`, and returns it as a
  boolean.

  Unlike a failed match, a failed check does not end the iteration. The
  summary shows how often each check passed, and thresholds can limit how
  many fail:

      Stampede.check("status is 200", response.status == 200)

      thresholds: [{"status is 200", failed_rate: 0.01}]
  """
  @spec check(String.t(), as_boolean(term())) :: boolean()
  def check(name, condition) when is_binary(name) do
    passed? = !!condition
    Metrics.check(Metrics.current(), name, passed?)
    passed?
  end
end
