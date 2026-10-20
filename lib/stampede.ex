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

  Every metric has a name and is either a timing or a counter. Stampede
  records these on its own:

    * `"iteration"` - how long each successful `c:Stampede.Scenario.run/1` took
    * `"iteration.errors"` - iterations that raised, threw or exited
    * `"vu.crashes"` - VUs that crashed and had to be replaced
    * the connection and channel metrics listed in `Stampede.Channels`
    * the page, join and event metrics listed in `Stampede.LiveView`

  Record your own with `measure/2`, `record/3` and `increment/2`. Use
  different names for timings and counters.

  Timings are counted in buckets that grow by 2% each, so every percentile
  in a `Stampede.Result` is within 1% of the exact value, however many samples
  the run collected.
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

    * `:thresholds` - a list of `{metric, limits}` tuples, such as
      `{"channel.join", p95: 250, max: 1_000}`. Each limit is the highest
      value the statistic may have for the run to pass. Timings have `:min`,
      `:mean`, `:p50`, `:p90`, `:p95`, `:p99` and `:max`, in milliseconds.
      Every metric has `:count` and `:rate`, per second. Thresholds on a
      timing with no samples fail, while a counter with no samples is zero.

    * `:progress` - prints the number of VUs, iterations and errors every
      second. Defaults to `false`.

  Durations are milliseconds or anything else `Kernel.to_timeout/1` accepts,
  such as `[second: 30]` or `Duration.new!(minute: 1)`.
  """
  @spec run(module(), keyword()) :: Stampede.Result.t()
  defdelegate run(scenario, opts \\ []), to: Stampede.Runner

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
    microseconds = System.convert_time_unit(duration, unit, :microsecond)
    Metrics.record(Metrics.current(), name, microseconds)
  end

  @doc """
  Adds `amount` to the counter `name`.
  """
  @spec increment(String.t(), pos_integer()) :: :ok
  def increment(name, amount \\ 1) when is_binary(name) and is_integer(amount) and amount > 0 do
    Metrics.increment(Metrics.current(), name, amount)
  end
end
