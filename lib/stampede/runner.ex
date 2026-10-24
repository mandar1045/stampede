defmodule Stampede.Runner do
  @moduledoc false

  alias Stampede.{Metrics, Plan, Result, Thresholds}
  alias Stampede.Runner.Driver

  @options [
    stages: nil,
    vus: 1,
    duration: nil,
    rate: nil,
    rate_stages: nil,
    max_vus: 1_000,
    graceful_stop: 0,
    thresholds: [],
    nodes: nil,
    progress: false
  ]

  def run(scenario, opts) when is_atom(scenario) and is_list(opts) do
    scenario |> prepare_run(opts) |> execute(false)
  end

  # Every scenario is checked and set up before any of them starts, so they
  # all start together.
  def run_parallel([_ | _] = scenarios, opts) when is_list(opts) do
    scenarios
    |> Enum.map(&prepare_run(&1, opts))
    |> Enum.map(fn run -> Task.async(fn -> execute(run, true) end) end)
    |> Task.await_many(:infinity)
  end

  def run_parallel(other, _opts) do
    raise ArgumentError, "expected a non-empty list of scenarios, got: #{inspect(other)}"
  end

  defp prepare_run(scenario, opts) when is_atom(scenario) and is_list(opts) do
    Code.ensure_loaded!(scenario)

    if not function_exported?(scenario, :run, 1) do
      raise ArgumentError, "expected #{inspect(scenario)} to implement Stampede.Scenario"
    end

    opts =
      scenario
      |> default_options()
      |> Keyword.merge(opts)
      |> Keyword.validate!(@options)

    plan = Plan.from_options(opts)
    thresholds = Thresholds.normalize(opts[:thresholds])
    nodes = nodes!(opts[:nodes])
    Enum.each(nodes, &prepare!(&1, scenario))
    graceful_stop = Plan.milliseconds!(opts[:graceful_stop])
    data = if function_exported?(scenario, :setup, 1), do: scenario.setup(opts)

    %{
      scenario: scenario,
      opts: opts,
      plan: plan,
      thresholds: thresholds,
      nodes: nodes,
      graceful_stop: graceful_stop,
      data: data
    }
  end

  defp execute(run, named?) do
    %{scenario: scenario, opts: opts, thresholds: thresholds, nodes: nodes} = run

    metadata = %{scenario: scenario, options: opts}
    :telemetry.execute([:stampede, :run, :start], %{system_time: System.system_time()}, metadata)
    started_at = System.monotonic_time()

    config = %{
      controller: self(),
      scenario: scenario,
      data: run.data,
      plan: run.plan,
      graceful_stop: run.graceful_stop,
      count: length(nodes)
    }

    drivers = start_drivers(nodes, config)
    Enum.each(drivers, fn {pid, _driver} -> send(pid, :go) end)

    state =
      collect(%{
        scenario: scenario,
        progress?: opts[:progress],
        named?: named?,
        running: drivers,
        count: map_size(drivers),
        pending: %{},
        next_index: 0,
        timeline: [],
        last_at: 0,
        iterations: 0,
        errors: 0,
        finals: []
      })

    state = flush(state, true)
    duration = state.finals |> Enum.map(& &1.duration) |> Enum.max()
    summary = state.finals |> Enum.map(& &1.rows) |> Metrics.merge() |> Metrics.summary(duration)

    result =
      Result.new(
        scenario,
        duration,
        summary,
        Thresholds.evaluate(thresholds, summary.metrics),
        Enum.reverse(state.timeline)
      )

    measurements = %{duration: System.monotonic_time() - started_at}

    :telemetry.execute([:stampede, :run, :stop], measurements, %{
      scenario: scenario,
      result: result
    })

    result
  end

  defp default_options(scenario) do
    if function_exported?(scenario, :options, 0), do: scenario.options(), else: []
  end

  defp nodes!(nil), do: [node()]

  defp nodes!([_ | _] = nodes) do
    nodes = Enum.uniq(nodes)

    if nodes != [node()] and not Node.alive?() do
      raise ArgumentError,
            "expected this node to be named to reach other nodes, " <>
              "start it with --sname or --name"
    end

    for node <- nodes, node != node() do
      if not is_atom(node) or Node.ping(node) != :pong do
        raise ArgumentError, "could not connect to node #{inspect(node)}"
      end
    end

    nodes
  end

  defp nodes!(other) do
    raise ArgumentError, "expected :nodes to be a non-empty list of nodes, got: #{inspect(other)}"
  end

  # Every node runs Stampede and the scenario. A scenario compiled to a .beam
  # file is loaded on the nodes that do not have it yet.
  defp prepare!(node, _scenario) when node == node(), do: :ok

  defp prepare!(node, scenario) do
    case :erpc.call(node, Application, :ensure_all_started, [:stampede]) do
      {:ok, _apps} ->
        :ok

      {:error, reason} ->
        raise ArgumentError, "could not start Stampede on #{node}: #{inspect(reason)}"
    end

    if not :erpc.call(node, Code, :ensure_loaded?, [scenario]) do
      case :code.get_object_code(scenario) do
        {^scenario, binary, file} ->
          {:module, ^scenario} = :erpc.call(node, :code, :load_binary, [scenario, file, binary])

        :error ->
          raise ArgumentError, "#{inspect(scenario)} is not available on #{node}"
      end
    end

    :ok
  end

  defp start_drivers(nodes, config) do
    nodes
    |> Enum.with_index()
    |> Map.new(fn {node, index} ->
      config = Map.put(config, :index, index)

      {:ok, pid} =
        if node == node(),
          do: Driver.start(config),
          else: :erpc.call(node, Driver, :start, [config])

      {pid, {node, Process.monitor(pid)}}
    end)
  end

  defp collect(%{running: running} = state) when map_size(running) == 0, do: state

  defp collect(state) do
    running = state.running

    receive do
      {:interval, pid, interval} when is_map_key(running, pid) ->
        state |> add_interval(interval) |> flush(false) |> collect()

      {:done, pid, final} when is_map_key(running, pid) ->
        {{_node, monitor}, running} = Map.pop!(running, pid)
        Process.demonitor(monitor, [:flush])
        collect(%{state | running: running, finals: [final | state.finals]})

      {:DOWN, _monitor, :process, pid, reason} when is_map_key(running, pid) ->
        for {other, _driver} <- running, other != pid, do: send(other, :stop)
        {node, _monitor} = Map.fetch!(running, pid)
        raise "lost the VUs on #{node}: #{inspect(reason)}"
    end
  end

  defp add_interval(state, interval) do
    entry = Map.get(state.pending, interval.index, %{reports: 0, at: 0, vus: 0, rows: %{}})

    entry = %{
      reports: entry.reports + 1,
      at: max(entry.at, interval.at),
      vus: entry.vus + interval.vus,
      rows: Map.merge(entry.rows, interval.delta, fn _key, left, right -> left + right end)
    }

    %{state | pending: Map.put(state.pending, interval.index, entry)}
  end

  # Turns each second into a point of the timeline once every node reported
  # it, or at the end of the run, whatever was reported.
  defp flush(state, all?) do
    with {:ok, entry} <- Map.fetch(state.pending, state.next_index),
         true <- all? or entry.reports == state.count do
      state
      |> Map.update!(:pending, &Map.delete(&1, state.next_index))
      |> Map.update!(:next_index, &(&1 + 1))
      |> add_point(entry)
      |> flush(all?)
    else
      _incomplete -> state
    end
  end

  defp add_point(state, entry) do
    summary = Metrics.summary(entry.rows, entry.at - state.last_at)
    point = %{at: entry.at, vus: entry.vus, metrics: summary.metrics}
    iterations = state.iterations + Metrics.count(entry.rows, "iteration")
    errors = state.errors + Metrics.count(entry.rows, "iteration.errors")

    :telemetry.execute([:stampede, :run, :interval], %{vus: entry.vus}, %{
      scenario: state.scenario,
      interval: point
    })

    if state.progress? do
      name = if state.named?, do: "  #{inspect(state.scenario)}", else: ""

      IO.puts(
        "#{seconds(entry.at)}#{name}  vus: #{entry.vus}  iterations: #{iterations}  " <>
          "errors: #{errors}"
      )
    end

    %{
      state
      | timeline: [point | state.timeline],
        last_at: entry.at,
        iterations: iterations,
        errors: errors
    }
  end

  defp seconds(milliseconds) do
    String.pad_leading(:erlang.float_to_binary(milliseconds / 1000, decimals: 1) <> "s", 7)
  end
end
