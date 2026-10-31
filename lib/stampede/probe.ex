defmodule Stampede.Probe do
  @moduledoc false

  # Watches the application under test from the inside during a run. An agent
  # runs on each of the application's nodes for as long as the run does, and
  # sends how busy the node is every second. What it times with telemetry
  # comes back at the end, as `server.*` metrics. The application needs no
  # changes: its node is reached over Erlang distribution, and the agent's
  # code is loaded there and removed afterwards.

  alias Stampede.Metrics
  alias Stampede.Probe.Agent

  @modules [Agent, Metrics]
  @stop_timeout 5_000

  # Starts an agent on each of `nodes`, sending to the calling process.
  def start(nil), do: %{}

  def start(nodes) do
    nodes
    |> List.wrap()
    |> Enum.uniq()
    |> Map.new(fn node ->
      connect!(node)
      loaded = load(node)
      {:ok, pid} = call(node, Agent, :start, [self()])
      {pid, %{node: node, monitor: Process.monitor(pid), loaded: loaded}}
    end)
  end

  # Stops the agents and returns the rows of what they timed.
  def stop(probes) do
    for {pid, probe} <- probes do
      send(pid, :stop)
      rows = await_rows(pid, probe.monitor)
      unload(probe)
      rows
    end
  end

  defp await_rows(pid, monitor) do
    receive do
      {:probe, ^pid, _sample} ->
        await_rows(pid, monitor)

      {:probe_queues, ^pid, _queues} ->
        await_rows(pid, monitor)

      {:probe_done, ^pid, rows} ->
        Process.demonitor(monitor, [:flush])
        rows

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        []
    after
      @stop_timeout ->
        Process.demonitor(monitor, [:flush])
        []
    end
  end

  # A second of a run with several probes: adds up what can be added, and
  # keeps the busiest node's load.
  def merge_samples(samples) do
    Enum.reduce(samples, fn sample, merged ->
      Map.merge(merged, sample, fn
        :busy, a, b -> max(a, b)
        _key, a, b -> a + b
      end)
    end)
  end

  # What the agents saw over a whole run, at its peak.
  def summary(probes, _timeline, _queues) when map_size(probes) == 0, do: nil

  def summary(probes, timeline, queues) do
    samples = for %{server: server} <- timeline, do: server

    %{
      nodes: probes |> Map.values() |> Enum.map(&Atom.to_string(&1.node)) |> Enum.sort(),
      busy: peak(samples, :busy),
      memory: peak(samples, :memory),
      processes: peak(samples, :processes),
      run_queue: peak(samples, :run_queue),
      queues: queues |> Enum.sort_by(&(-&1.length)) |> Enum.take(5)
    }
  end

  defp peak(samples, key), do: samples |> Enum.map(& &1[key]) |> Enum.max(fn -> 0 end)

  defp connect!(node) when node == node(), do: :ok

  defp connect!(node) do
    if not Node.alive?() do
      raise ArgumentError,
            "expected this node to be named to reach #{node}, such as with: " <>
              "elixir --name loader@127.0.0.1 --cookie <the app's cookie> -S mix stampede.run ..."
    end

    if not Node.connect(node) do
      raise ArgumentError,
            "could not connect to #{node} to probe it, check that it's running, " <>
              "and that this node has the same cookie"
    end
  end

  # Returns the modules it had to load, which are only those the node lacks.
  defp load(node) when node == node(), do: []

  defp load(node) do
    for module <- @modules, not call(node, Code, :ensure_loaded?, [module]) do
      {^module, binary, file} = :code.get_object_code(module)
      {:module, ^module} = call(node, :code, :load_binary, [module, file, binary])
      module
    end
  end

  defp unload(%{node: node, loaded: loaded}) do
    for module <- loaded do
      call(node, :code, :delete, [module])
      call(node, :code, :soft_purge, [module])
    end
  catch
    # The node went away, and the code went with it.
    :error, {:erpc, _reason} -> :ok
  end

  defp call(node, module, function, args) when node == node() do
    apply(module, function, args)
  end

  defp call(node, module, function, args), do: :erpc.call(node, module, function, args)
end

defmodule Stampede.Probe.Agent do
  @moduledoc false

  # Runs on the application's node, so it can't rely on anything but Elixir,
  # Stampede.Metrics and, if the application has it, telemetry. It stops by
  # itself if the run goes away.

  alias Stampede.Metrics

  @interval 1_000
  # Going through every process takes a while on a busy node, so it's only
  # done every so often, in a process that doesn't compete with the app's.
  @scan_every 10
  @long_queue 100

  @timings %{
    [:phoenix, :endpoint, :stop] => "server.http",
    [:phoenix, :channel_joined] => "server.channel.join",
    [:phoenix, :channel_handled_in] => "server.channel.event",
    [:phoenix, :live_view, :mount, :stop] => "server.live.mount",
    [:phoenix, :live_view, :handle_event, :stop] => "server.live.event"
  }

  def start(controller), do: {:ok, spawn(fn -> init(controller) end)}

  defp init(controller) do
    monitor = Process.monitor(controller)
    Process.flag(:priority, :high)
    :erlang.system_flag(:scheduler_wall_time, true)
    table = Metrics.new()
    attach(table)
    Process.send_after(self(), :sample, @interval)

    loop(%{
      controller: controller,
      monitor: monitor,
      table: table,
      scheduler_time: scheduler_time(),
      ticks: 0
    })
  end

  defp loop(%{monitor: monitor} = state) do
    receive do
      :sample ->
        Process.send_after(self(), :sample, @interval)
        state |> sample() |> scan() |> loop()

      {:queues, queues} ->
        if queues != [], do: send(state.controller, {:probe_queues, self(), queues})
        loop(state)

      :stop ->
        detach()
        send(state.controller, {:probe_done, self(), Metrics.rows(state.table)})

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        detach()
    end
  end

  defp sample(state) do
    scheduler_time = scheduler_time()
    memory = :erlang.memory()

    sample = %{
      busy: busy(state.scheduler_time, scheduler_time),
      memory: memory[:total],
      processes: :erlang.system_info(:process_count),
      run_queue: :erlang.statistics(:total_run_queue_lengths)
    }

    send(state.controller, {:probe, self(), sample})
    %{state | scheduler_time: scheduler_time, ticks: state.ticks + 1}
  end

  defp scan(%{ticks: ticks} = state) when rem(ticks, @scan_every) == 1 do
    agent = self()
    spawn(fn -> send(agent, {:queues, longest_queues()}) end)
    state
  end

  defp scan(state), do: state

  defp longest_queues do
    Process.list()
    |> Enum.flat_map(fn pid ->
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, length} when length >= @long_queue -> [{length, pid}]
        _short_or_gone -> []
      end
    end)
    |> Enum.sort(:desc)
    |> Enum.take(5)
    |> Enum.map(fn {length, pid} -> %{length: length, process: describe(pid)} end)
  end

  defp describe(pid) do
    case Process.info(pid, [:registered_name, :dictionary, :current_function]) do
      nil ->
        "gone"

      info ->
        case info[:registered_name] do
          name when is_atom(name) and name not in [nil, []] -> inspect(name)
          _none -> inspect(info[:dictionary][:"$initial_call"] || info[:current_function])
        end
    end
  end

  defp scheduler_time do
    count = :erlang.system_info(:schedulers)

    :erlang.statistics(:scheduler_wall_time)
    |> Enum.filter(fn {id, _active, _total} -> id <= count end)
    |> Enum.sort()
  end

  defp busy(before, now) do
    {active, total} =
      Enum.zip_reduce(before, now, {0, 0}, fn {_, active1, total1},
                                              {_, active2, total2},
                                              {a, t} ->
        {a + active2 - active1, t + total2 - total1}
      end)

    if total > 0, do: active / total, else: 0.0
  end

  defp attach(table) do
    if Code.ensure_loaded?(:telemetry) do
      repos = Enum.flat_map(Application.loaded_applications(), &repo_events/1)
      events = Map.merge(@timings, Map.new(repos, &{&1, :ecto}))

      :telemetry.attach_many(handler(), Map.keys(events), &__MODULE__.handle_event/4, %{
        table: table,
        events: events
      })
    end
  end

  defp detach do
    if Code.ensure_loaded?(:telemetry), do: :telemetry.detach(handler())
  end

  defp handler, do: {__MODULE__, self()}

  defp repo_events({app, _description, _version}) do
    for repo <- Application.get_env(app, :ecto_repos, []), do: query_event(repo)
  end

  defp query_event(repo) do
    case repo.config()[:telemetry_prefix] do
      nil -> default_prefix(repo)
      prefix -> prefix
    end
    |> Kernel.++([:query])
  rescue
    _not_started -> default_prefix(repo) ++ [:query]
  end

  defp default_prefix(repo) do
    repo |> Module.split() |> Enum.map(&String.to_atom(Macro.underscore(&1)))
  end

  @doc false
  def handle_event(event, measurements, _metadata, %{table: table, events: events}) do
    case events[event] do
      :ecto ->
        record(table, "server.ecto.query", measurements[:total_time])
        record(table, "server.ecto.queue", measurements[:queue_time])

      name ->
        record(table, name, measurements[:duration])
    end
  end

  defp record(table, name, duration) when is_integer(duration) and duration >= 0 do
    Metrics.record(table, name, duration)
  end

  defp record(_table, _name, _duration), do: :ok
end
