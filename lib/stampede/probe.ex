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

  # Stops the agents and returns the rows of what they timed. An app that
  # crashed during the run can't answer, so `latest` has the last rows each
  # agent sent.
  def stop(probes, latest \\ %{}) do
    for {pid, probe} <- probes do
      send(pid, :stop)
      rows = await_rows(pid, probe.monitor, Map.get(latest, pid, []))
      unload(probe)
      rows
    end
  end

  defp await_rows(pid, monitor, latest) do
    receive do
      {:probe, ^pid, _sample} ->
        await_rows(pid, monitor, latest)

      {:probe_queues, ^pid, _queues} ->
        await_rows(pid, monitor, latest)

      {:probe_rows, ^pid, rows} ->
        await_rows(pid, monitor, rows)

      {:probe_done, ^pid, rows} ->
        Process.demonitor(monitor, [:flush])
        rows

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        latest
    after
      @stop_timeout ->
        Process.demonitor(monitor, [:flush])
        latest
    end
  end

  # A second of a run with several probes: adds up what can be added, and
  # keeps the busiest node's load.
  def merge_samples(samples) do
    Enum.reduce(samples, fn sample, merged ->
      Map.merge(merged, sample, fn
        :busy, a, b ->
          max(a, b)

        # Each node sees the same database.
        :database, a, _b ->
          a

        :pool, a, b ->
          %{
            size: a.size + b.size,
            queries: a.queries + b.queries,
            wait_ms: max(a.wait_ms, b.wait_ms)
          }

        _key, a, b ->
          a + b
      end)
    end)
  end

  # What the agents saw over a whole run, at its peak.
  def summary(probes, timeline, queues, lost \\ [])

  def summary(probes, _timeline, _queues, _lost) when map_size(probes) == 0, do: nil

  def summary(probes, timeline, queues, lost) do
    samples = for %{server: server} <- timeline, do: server

    %{
      nodes: probes |> Map.values() |> Enum.map(&Atom.to_string(&1.node)) |> Enum.sort(),
      lost: lost |> Enum.map(&Atom.to_string(probes[&1].node)) |> Enum.sort(),
      busy: peak(samples, :busy),
      memory: peak(samples, :memory),
      processes: peak(samples, :processes),
      run_queue: peak(samples, :run_queue),
      queues: queues |> Enum.sort_by(&(-&1.length)) |> Enum.take(5),
      database: database_peak(samples),
      pool: pool_peak(samples)
    }
  end

  defp peak(samples, key), do: samples |> Enum.map(& &1[key]) |> Enum.max(fn -> 0 end)

  defp database_peak(samples) do
    case for %{database: database} <- samples, do: database do
      [] ->
        nil

      databases ->
        Map.new([:commits, :writes, :reads, :connections, :active], &{&1, peak(databases, &1)})
    end
  end

  defp pool_peak(samples) do
    case for %{pool: pool} <- samples, do: pool do
      [] -> nil
      pools -> %{size: peak(pools, :size), wait_ms: peak(pools, :wait_ms)}
    end
  end

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
  # Stampede.Metrics and, if the application has them, telemetry and Postgrex.
  # It stops by itself if the run goes away.
  #
  # When the app has an Ecto repo, it also sends how long queries waited for a
  # connection from the pool each second. When that repo uses Postgres, it
  # opens one connection of its own with the repo's settings, outside the
  # app's pool, and sends Postgres's own numbers every second too.

  alias Stampede.Metrics

  @interval 1_000
  # Asking a process for its queue wakes it, so on a node with a process per
  # connection, a full scan wakes them all, and costs the app real CPU. Past
  # this many, it only asks the named ones, where bottlenecks usually are,
  # such as a PubSub or a pool, and a few others picked at random.
  @scan_every 10
  @scan_all_up_to 20_000
  @scan_sample 1_000
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
    pool = :ets.new(__MODULE__, [:public, :set, write_concurrency: true])
    repos = repos()
    attach(table, pool, repos)
    start_database(repos)
    Process.send_after(self(), :sample, @interval)

    loop(%{
      controller: controller,
      monitor: monitor,
      table: table,
      scheduler_time: scheduler_time(),
      ticks: 0,
      pool: pool,
      pool_size: pool_size(repos),
      pool_last: {0, 0},
      database: nil
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

      {:database, database} ->
        loop(%{state | database: database})

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

    {pool, pool_last} = pool_sample(state)

    sample =
      %{
        busy: busy(state.scheduler_time, scheduler_time),
        memory: memory[:total],
        processes: :erlang.system_info(:process_count),
        run_queue: :erlang.statistics(:total_run_queue_lengths)
      }
      |> put_some(:pool, pool)
      |> put_some(:database, state.database)

    send(state.controller, {:probe, self(), sample})

    %{
      state
      | scheduler_time: scheduler_time,
        ticks: state.ticks + 1,
        pool_last: pool_last,
        database: nil
    }
  end

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  # The queries since the last second, and how long they waited on average for
  # a connection from the pool.
  defp pool_sample(%{pool_size: nil} = state), do: {nil, state.pool_last}

  defp pool_sample(state) do
    {sum, count} =
      case :ets.lookup(state.pool, :wait) do
        [{:wait, sum, count}] -> {sum, count}
        [] -> {0, 0}
      end

    {last_sum, last_count} = state.pool_last
    queries = count - last_count
    wait_ms = if queries > 0, do: (sum - last_sum) / queries / 1000, else: 0.0
    {%{size: state.pool_size, queries: queries, wait_ms: wait_ms}, {sum, count}}
  end

  defp scan(%{ticks: ticks} = state) when rem(ticks, @scan_every) == 1 do
    agent = self()
    spawn(fn -> send(agent, {:queues, longest_queues()}) end)
    send(state.controller, {:probe_rows, self(), Metrics.rows(state.table)})
    state
  end

  defp scan(state), do: state

  defp longest_queues do
    processes_to_scan()
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

  defp processes_to_scan do
    if :erlang.system_info(:process_count) <= @scan_all_up_to do
      Process.list()
    else
      named = for name <- Process.registered(), pid = Process.whereis(name), do: pid
      Enum.uniq(named ++ Enum.take_random(Process.list(), @scan_sample))
    end
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

  defp attach(table, pool, repos) do
    if Code.ensure_loaded?(:telemetry) do
      events = Map.merge(@timings, Map.new(repos, &{query_event(&1), :ecto}))

      :telemetry.attach_many(handler(), Map.keys(events), &__MODULE__.handle_event/4, %{
        table: table,
        pool: pool,
        events: events
      })
    end
  end

  defp repos do
    for {app, _description, _version} <- Application.loaded_applications(),
        repo <- Application.get_env(app, :ecto_repos, []),
        uniq: true,
        do: repo
  end

  defp repo_config(repo) do
    repo.config()
  rescue
    _not_started -> []
  end

  defp pool_size([]), do: nil
  defp pool_size(repos), do: repos |> Enum.map(&(repo_config(&1)[:pool_size] || 10)) |> Enum.sum()

  defp detach do
    if Code.ensure_loaded?(:telemetry), do: :telemetry.detach(handler())
  end

  defp handler, do: {__MODULE__, self()}

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
  def handle_event(event, measurements, _metadata, %{table: table, events: events} = config) do
    case events[event] do
      :ecto ->
        record(table, "server.ecto.query", measurements[:total_time])
        record(table, "server.ecto.queue", measurements[:queue_time])
        count_wait(config.pool, measurements[:queue_time])

      name ->
        record(table, name, measurements[:duration])
    end
  end

  defp record(table, name, duration) when is_integer(duration) and duration >= 0 do
    Metrics.record(table, name, duration)
  end

  defp record(_table, _name, _duration), do: :ok

  defp count_wait(pool, queue_time) do
    waited =
      if is_integer(queue_time),
        do: System.convert_time_unit(queue_time, :native, :microsecond),
        else: 0

    :ets.update_counter(pool, :wait, [{2, waited}, {3, 1}], {:wait, 0, 0})
  end

  @database_keys [
    :hostname,
    :port,
    :username,
    :password,
    :database,
    :ssl,
    :ssl_opts,
    :socket,
    :socket_dir,
    :socket_options,
    :parameters,
    :connect_timeout
  ]

  # Every commit, row and wait, for the database the app is using, from
  # Postgres's own statistics.
  @database_stats """
  select xact_commit, tup_inserted + tup_updated + tup_deleted, tup_fetched, blks_read, blks_hit, numbackends
  from pg_stat_database where datname = current_database()
  """

  @database_waits """
  select coalesce(wait_event_type || ':' || wait_event, 'running'), count(*)::int
  from pg_stat_activity
  where datname = current_database() and state = 'active' and pid <> pg_backend_pid()
  group by 1
  """

  defp start_database(repos) do
    with repo when repo != nil <- Enum.find(repos, &postgres?/1) do
      opts = repo |> repo_config() |> Keyword.take(@database_keys) |> Keyword.put(:pool_size, 1)
      agent = self()
      spawn(fn -> database_init(agent, opts) end)
    end
  end

  defp postgres?(repo) do
    Code.ensure_loaded?(Postgrex) and Code.ensure_loaded?(repo) and
      function_exported?(repo, :__adapter__, 0) and repo.__adapter__() == Ecto.Adapters.Postgres
  end

  defp database_init(agent, opts) do
    monitor = Process.monitor(agent)
    Process.flag(:trap_exit, true)

    case apply(Postgrex, :start_link, [opts]) do
      {:ok, conn} ->
        # The first reading is only a baseline, so it's taken right away.
        send(self(), :sample)
        database_loop(%{agent: agent, monitor: monitor, conn: conn, last: nil})

      _error ->
        :ok
    end
  end

  defp database_loop(%{monitor: monitor, conn: conn} = state) do
    receive do
      :sample ->
        Process.send_after(self(), :sample, @interval)
        state |> database_sample() |> database_loop()

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        Process.exit(conn, :shutdown)

      {:EXIT, ^conn, _reason} ->
        :ok
    end
  end

  defp database_sample(state) do
    with {:ok, %{rows: [[commits, writes, reads, blocks_read, blocks_hit, backends]]}} <-
           database_query(state.conn, @database_stats),
         {:ok, %{rows: waits}} <- database_query(state.conn, @database_waits) do
      counters =
        {System.monotonic_time(:millisecond), commits, writes, reads, blocks_read, blocks_hit}

      if state.last,
        do: send(state.agent, {:database, database_rates(state.last, counters, backends, waits)})

      %{state | last: counters}
    else
      _error -> state
    end
  end

  defp database_query(conn, sql) do
    apply(Postgrex, :query, [conn, sql, [], [timeout: 900]])
  catch
    :exit, _reason -> {:error, :timeout}
  end

  defp database_rates(before, now, backends, waits) do
    {t0, commits0, writes0, reads0, read0, hit0} = before
    {t1, commits1, writes1, reads1, read1, hit1} = now
    seconds = max(t1 - t0, 1) / 1000
    blocks = read1 - read0 + (hit1 - hit0)

    %{
      commits: (commits1 - commits0) / seconds,
      writes: (writes1 - writes0) / seconds,
      reads: (reads1 - reads0) / seconds,
      cache_hit: if(blocks > 0, do: (hit1 - hit0) / blocks),
      # Not counting the probe's own connection.
      connections: max(backends - 1, 0),
      active: waits |> Enum.map(fn [_wait, count] -> count end) |> Enum.sum(),
      waits: Map.new(waits, fn [wait, count] -> {wait, count} end)
    }
  end
end
