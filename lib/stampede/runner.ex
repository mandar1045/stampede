defmodule Stampede.Runner do
  @moduledoc false

  alias Stampede.{Limit, Metrics, Plan, Probe, Reporter, Result, Thresholds}
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
    find_limit: nil,
    nodes: nil,
    probe: nil,
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
      |> Keyword.merge(opts, &merge_option/3)
      |> Keyword.validate!(@options)

    thresholds = Thresholds.normalize(opts[:thresholds])
    limit = if opts[:find_limit], do: Limit.new!(opts[:find_limit], thresholds)

    plan =
      Plan.from_options(if limit, do: Keyword.merge(opts, Limit.plan_options(limit)), else: opts)

    nodes = nodes!(opts[:nodes])
    Enum.each(nodes, &prepare!(&1, scenario))
    warn_limits(scenario, plan, nodes)
    graceful_stop = Plan.milliseconds!(opts[:graceful_stop])
    data = if function_exported?(scenario, :setup, 1), do: scenario.setup(opts)

    %{
      scenario: scenario,
      opts: opts,
      plan: plan,
      thresholds: thresholds,
      limit: limit,
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

    # The run's own processes run at high priority, so that a node busy with
    # hundreds of thousands of VUs still collects reports and ends the run on
    # time, instead of stalling with them.
    priority = Process.flag(:priority, :high)
    printer = if opts[:progress], do: start_printer()
    probes = Probe.start(opts[:probe])

    state =
      try do
        drivers = start_drivers(nodes, config)
        Enum.each(drivers, fn {pid, _driver} -> send(pid, :go) end)

        %{
          scenario: scenario,
          printer: printer,
          probes: probes,
          server: %{},
          server_rows: %{},
          lost: [],
          queues: [],
          named?: named?,
          limit: run.limit,
          running: drivers,
          count: map_size(drivers),
          pending: %{},
          next_index: 0,
          timeline: [],
          last_at: 0,
          iterations: 0,
          errors: 0,
          finals: []
        }
        |> collect()
        |> flush(true)
      rescue
        exception ->
          Probe.stop(probes)
          reraise exception, __STACKTRACE__
      after
        stop_printer(printer)
        Process.flag(:priority, priority)
      end

    lost_rows = state.server_rows |> Map.take(state.lost) |> Map.values()
    server_rows = lost_rows ++ Probe.stop(Map.drop(probes, state.lost), state.server_rows)
    duration = state.finals |> Enum.map(& &1.duration) |> Enum.max()

    summary =
      Enum.map(state.finals, & &1.rows)
      |> Kernel.++(server_rows)
      |> Metrics.merge()
      |> Metrics.summary(duration)

    result =
      Result.new(
        scenario,
        duration,
        summary,
        Thresholds.evaluate(thresholds, summary.metrics),
        Enum.reverse(state.timeline)
      )
      |> with_limit(state.limit)
      |> Map.put(:server, Probe.summary(probes, state.timeline, state.queues, state.lost))

    measurements = %{duration: System.monotonic_time() - started_at}

    :telemetry.execute([:stampede, :run, :stop], measurements, %{
      scenario: scenario,
      result: result
    })

    result
  end

  # A run that looked for its limit passes when it found one. Its thresholds
  # were checked step by step, so the steps tell how it went.
  defp with_limit(result, nil), do: result

  defp with_limit(result, limit) do
    limit = Limit.summary(limit)
    %{result | limit: limit, thresholds: [], passed?: Limit.passed?(limit)}
  end

  # `:find_limit` options given to a run add to the scenario's own, so that
  # `--find-limit --up-to 500` keeps the scenario's other settings.
  defp merge_option(:find_limit, defaults, true) when is_list(defaults), do: defaults

  defp merge_option(:find_limit, defaults, given) when is_list(defaults) and is_list(given),
    do: Keyword.merge(defaults, given)

  defp merge_option(_key, _default, given), do: given

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
  # A VU that holds a connection takes about two processes and an open file
  # or two, so a big run can hit the limits of a node long before running out
  # of memory or CPU, and fail halfway with errors that don't say why.
  defp warn_limits(scenario, plan, nodes) do
    vus = ceil(Plan.peak_vus(plan) / length(nodes))

    for node <- nodes do
      %{processes: processes, files: files} =
        if node == node(), do: limits(), else: :erpc.call(node, __MODULE__, :limits, [])

      if vus * 2 > processes or vus * 2 > files do
        IO.warn(
          "#{inspect(scenario)} can run up to #{Reporter.amount(vus, :vus)} VUs on #{node}, " <>
            "which allows #{Reporter.amount(processes, :vus)} processes and " <>
            "#{Reporter.amount(files, :vus)} open files. A VU that holds a connection takes " <>
            "about two of each, so the run may fail. Raise them with " <>
            ~s(--erl "+P 4000000" and ulimit -n),
          []
        )
      end
    end
  end

  # The open files are the BEAM's port limit, or what the OS allows if that's
  # lower. The BEAM doesn't report the OS limit, but a shell it starts shares
  # it.
  @doc false
  def limits do
    ports = :erlang.system_info(:port_limit)

    files =
      with {:unix, _name} <- :os.type(),
           {limit, _rest} <- Integer.parse(to_string(:os.cmd(~c"ulimit -n"))) do
        min(limit, ports)
      else
        _other -> ports
      end

    %{processes: :erlang.system_info(:process_limit), files: files}
  end

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
    probes = state.probes

    receive do
      {:interval, pid, interval} when is_map_key(running, pid) ->
        state |> add_interval(interval) |> flush(false) |> collect()

      {:probe, pid, sample} when is_map_key(probes, pid) ->
        collect(put_in(state.server[pid], sample))

      {:probe_queues, pid, queues} when is_map_key(probes, pid) ->
        collect(%{state | queues: queues ++ state.queues})

      {:probe_rows, pid, rows} when is_map_key(probes, pid) ->
        collect(put_in(state.server_rows[pid], rows))

      # The app went down, which is worth knowing, so the run goes on to show
      # what that did.
      {:DOWN, _monitor, :process, pid, _reason} when is_map_key(probes, pid) ->
        server = Map.delete(state.server, pid)
        collect(%{state | server: server, lost: [pid | state.lost]})

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
    entry =
      Map.get(state.pending, interval.index, %{reports: 0, at: 0, vus: 0, busy: 0.0, rows: %{}})

    # A second is as busy as the busiest node was.
    entry = %{
      reports: entry.reports + 1,
      at: max(entry.at, interval.at),
      vus: entry.vus + interval.vus,
      busy: max(entry.busy, interval.busy),
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
    state = check_limit(state, entry)
    summary = Metrics.summary(entry.rows, entry.at - state.last_at)
    point = %{at: entry.at, vus: entry.vus, busy: entry.busy, metrics: summary.metrics}
    point = with_server(point, state.server)
    iterations = state.iterations + Metrics.count(entry.rows, "iteration")
    errors = state.errors + Metrics.count(entry.rows, "iteration.errors")

    :telemetry.execute([:stampede, :run, :interval], %{vus: entry.vus}, %{
      scenario: state.scenario,
      interval: point
    })

    if state.printer do
      name = if state.named?, do: "  #{inspect(state.scenario)}", else: ""

      print(
        state,
        "#{seconds(entry.at)}#{name}  vus: #{entry.vus}  iterations: #{iterations}  " <>
          "errors: #{errors}  load test busy: #{round(entry.busy * 100)}%"
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

  # The latest of what the probes saw. They keep their own time, so it's as
  # close to this second as they've reported.
  defp with_server(point, server) when map_size(server) == 0, do: point

  defp with_server(point, server) do
    Map.put(point, :server, server |> Map.values() |> Probe.merge_samples())
  end

  # Once a step fails, the drivers wrap up, and later seconds are not checked.
  defp check_limit(%{limit: %Limit{} = limit} = state, entry)
       when not is_map_key(state, :wrapped) do
    server_busy = state.server |> Map.values() |> Enum.map(& &1.busy) |> Enum.max(fn -> 0.0 end)

    case Limit.add_second(limit, entry.at, entry.rows, entry.busy, server_busy, state.lost != []) do
      {:continue, new_limit} ->
        print_step(state, limit, new_limit)
        %{state | limit: new_limit}

      {:stop, new_limit} ->
        print_step(state, limit, new_limit)
        for {pid, _driver} <- state.running, do: send(pid, :wrap_up)
        state |> Map.put(:limit, new_limit) |> Map.put(:wrapped, true)
    end
  end

  defp check_limit(state, _entry), do: state

  defp print_step(%{printer: printer} = state, old, %Limit{steps: [step | _]} = new)
       when printer != nil and length(new.steps) > length(old.steps) do
    name = if state.named?, do: "  #{inspect(state.scenario)}", else: ""
    status = if step.passed?, do: "held", else: "over the limit"
    amount = Reporter.amount(step.target, new.by)
    unit = if new.by == :vus, do: "VUs", else: "iterations/s"
    print(state, "   step#{name}  #{amount} #{unit}: #{status}")
  end

  defp print_step(_state, _old, _new), do: :ok

  # Progress is printed by a process of its own, since a console slowed down
  # by a busy node would otherwise hold up the run with it.
  defp start_printer, do: spawn_link(&printer/0)

  defp printer do
    receive do
      {:print, line} ->
        IO.puts(line)
        printer()

      {:stop, from} ->
        send(from, {:printed, self()})
    end
  end

  defp print(state, line), do: send(state.printer, {:print, line})

  defp stop_printer(nil), do: :ok

  defp stop_printer(printer) do
    send(printer, {:stop, self()})

    receive do
      {:printed, ^printer} -> :ok
    end
  end

  defp seconds(milliseconds) do
    String.pad_leading(:erlang.float_to_binary(milliseconds / 1000, decimals: 1) <> "s", 7)
  end
end
