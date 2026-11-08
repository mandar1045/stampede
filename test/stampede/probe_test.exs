defmodule Stampede.ProbeTest do
  # What the agent times is everything on this node, and the Ecto test changes
  # the application's environment, so no other test may run alongside.
  use ExUnit.Case, async: false

  alias Stampede.Test.{Lobby, Observed}

  test "reports how the app's node is doing, every second and at its peak" do
    result = Stampede.run(Observed, vus: 1, duration: 2_500, probe: node())

    assert %{nodes: [name], busy: busy, memory: memory, processes: processes} = result.server
    assert name == Atom.to_string(node())
    assert busy >= 0 and busy <= 1
    assert memory > 0
    assert processes > 0
    assert result.server.run_queue >= 0
    assert result.server.queues == []

    assert [%{server: %{busy: _, memory: _, processes: _, run_queue: _}} | _] =
             Enum.filter(result.timeline, &Map.has_key?(&1, :server))
  end

  test "has no :server without a probe" do
    result = Stampede.run(Observed, vus: 1, duration: 100)

    assert result.server == nil
    refute Enum.any?(result.timeline, &Map.has_key?(&1, :server))
  end

  test "times what the app does, as server metrics that merge with the rest" do
    result = Stampede.run(Lobby, vus: 2, duration: 1_500, graceful_stop: 10_000, probe: node())

    assert result.metrics["server.channel.join"].count >= 2
    assert result.metrics["server.channel.event"].count >= 2
    # A ping can take under a microsecond, which rounds down to 0, but a join can't.
    assert result.metrics["server.channel.join"].p95 > 0
    assert result.metrics["channel.push"].count > 0
  end

  test "takes thresholds on what the app timed" do
    thresholds = [{"server.channel.event", p95: 60_000}, {"server.channel.join", count: 0}]

    result =
      Stampede.run(Lobby, vus: 1, duration: 1_500, probe: node(), thresholds: thresholds)

    assert [%{passed?: true}, %{metric: "server.channel.join", passed?: false}] =
             result.thresholds
  end

  defmodule Repo do
    def config, do: [telemetry_prefix: [:my, :repo]]
  end

  defmodule Querying do
    use Stampede.Scenario

    @impl true
    def run(_vu) do
      native = System.convert_time_unit(5, :millisecond, :native)
      :telemetry.execute([:my, :repo, :query], %{total_time: native, queue_time: native}, %{})
      Process.sleep(50)
    end
  end

  test "finds the app's Ecto repos and times their queries" do
    Application.put_env(:stampede, :ecto_repos, [Repo])
    on_exit(fn -> Application.delete_env(:stampede, :ecto_repos) end)

    result = Stampede.run(Querying, vus: 1, duration: 500, probe: node())

    assert result.metrics["server.ecto.query"].p50 >= 4
    assert result.metrics["server.ecto.queue"].p50 >= 4
  end

  test "shows how long queries waited for a connection from the pool, every second" do
    Application.put_env(:stampede, :ecto_repos, [Repo])
    on_exit(fn -> Application.delete_env(:stampede, :ecto_repos) end)

    result = Stampede.run(Querying, vus: 1, duration: 2_500, probe: node())

    assert [%{size: 10, wait_ms: wait} | _] =
             for(%{server: %{pool: pool}} <- result.timeline, pool.queries > 0, do: pool)

    assert wait >= 4
    assert %{size: 10, wait_ms: peak} = result.server.pool
    assert peak >= 4
  end

  defmodule PostgresRepo do
    def __adapter__, do: Ecto.Adapters.Postgres

    def config do
      Stampede.TestPostgres.opts() ++ [telemetry_prefix: [:test, :postgres_repo], pool_size: 3]
    end
  end

  defmodule Writing do
    use Stampede.Scenario

    @impl true
    def setup(_opts) do
      {:ok, conn} = Postgrex.start_link(Stampede.TestPostgres.opts())

      Postgrex.query!(
        conn,
        "create table if not exists stampede_probe_test (id bigserial primary key)",
        []
      )

      conn
    end

    @impl true
    def run(vu) do
      Postgrex.query!(vu.data, "insert into stampede_probe_test default values", [])
      # A busy session shares its numbers with pg_stat_database only now and
      # then, about once a second, which a short test on a slow machine can
      # miss entirely. This shares them after every insert.
      Postgrex.query!(vu.data, "select pg_stat_force_next_flush()", [])
      Process.sleep(20)
    end
  end

  @tag :postgres
  test "reads Postgres's own numbers with the app's repo settings, outside its pool" do
    Application.put_env(:stampede, :ecto_repos, [PostgresRepo])
    on_exit(fn -> Application.delete_env(:stampede, :ecto_repos) end)

    result = Stampede.run(Writing, vus: 2, duration: 4_000, probe: node())

    databases = for %{server: %{database: database}} <- result.timeline, do: database
    assert Enum.any?(databases, &(&1.commits > 0 and &1.writes > 0))
    assert Enum.all?(databases, &is_map(&1.waits))
    assert %{commits: commits, writes: writes, connections: connections} = result.server.database
    assert commits > 0 and writes > 0 and connections >= 1
    assert result.server.pool.size == 3
  end

  test "adds up what several app nodes saw, but counts their database once" do
    one = %{
      busy: 0.5,
      memory: 10,
      processes: 1,
      run_queue: 0,
      pool: %{size: 10, queries: 5, wait_ms: 2.0},
      database: %{commits: 100.0}
    }

    two = %{
      busy: 0.7,
      memory: 20,
      processes: 2,
      run_queue: 1,
      pool: %{size: 10, queries: 7, wait_ms: 9.0},
      database: %{commits: 100.0}
    }

    assert %{
             busy: 0.7,
             memory: 30,
             processes: 3,
             run_queue: 1,
             pool: pool,
             database: %{commits: 100.0}
           } =
             Stampede.Probe.merge_samples([one, two])

    assert pool == %{size: 20, queries: 12, wait_ms: 9.0}
  end

  defmodule Clogged do
    use Stampede.Scenario

    @impl true
    def run(vu) do
      pid = :persistent_term.get({__MODULE__, :target})
      for _ <- 1..200, do: send(pid, vu.id)
      Process.sleep(5_000)
    end
  end

  test "finds the longest message queues" do
    # Never reads its messages, as a process that can't keep up wouldn't.
    pid = spawn_link(fn -> Process.sleep(:infinity) end)
    :persistent_term.put({Clogged, :target}, pid)

    result = Stampede.run(Clogged, vus: 2, duration: 2_500, probe: node())

    assert [%{length: length, process: process} | _] = result.server.queues
    assert length >= 200
    assert is_binary(process)
  end

  test "leaves nothing behind" do
    Stampede.run(Observed, vus: 1, duration: 300, probe: node())

    handlers = :telemetry.list_handlers([:phoenix, :channel_joined])
    refute Enum.any?(handlers, &match?({Stampede.Probe.Agent, _pid}, &1.id))
    assert Process.info(self(), :messages) == {:messages, []}
  end

  test "raises when it can't reach the node" do
    assert_raise ArgumentError, ~r/could not connect|to be named/, fn ->
      Stampede.run(Observed, vus: 1, duration: 100, probe: :"nobody@127.0.0.1")
    end
  end

  describe "on another node" do
    @describetag :distributed

    setup do
      {:ok, peer, node} =
        :peer.start(%{
          name: :peer.random_name(~c"stampede-probed"),
          host: ~c"127.0.0.1",
          longnames: true
        })

      # Elixir, but neither Stampede nor telemetry, like an app we know
      # nothing about.
      :ok = :erpc.call(node, :code, :add_paths, [[:code.lib_dir(:elixir) ++ ~c"/ebin"]])

      on_exit(fn ->
        try do
          :peer.stop(peer)
        catch
          # The test that takes the node down has already stopped it.
          :exit, _reason -> :ok
        end
      end)

      %{peer: node}
    end

    test "loads its code there, and removes it after", %{peer: peer} do
      assert :erpc.call(peer, :code, :is_loaded, [Stampede.Metrics]) == false

      result = Stampede.run(Observed, vus: 1, duration: 2_500, probe: peer)

      assert result.server.nodes == [Atom.to_string(peer)]
      assert result.server.processes > 0
      assert :erpc.call(peer, :code, :is_loaded, [Stampede.Metrics]) == false
      assert :erpc.call(peer, :code, :is_loaded, [Stampede.Probe.Agent]) == false
    end

    test "notices when the app's node goes down, and keeps what it timed", %{peer: peer} do
      Task.start(fn ->
        Process.sleep(1_500)
        :erpc.cast(peer, :erlang, :halt, [])
      end)

      result = Stampede.run(Observed, vus: 1, duration: 2_500, probe: peer)

      assert result.server.lost == [Atom.to_string(peer)]
      assert result.server.nodes == [Atom.to_string(peer)]
    end

    test "its agent stops by itself when the run goes away", %{peer: peer} do
      high_priority = fn ->
        for pid <- :erpc.call(peer, :erlang, :processes, []),
            :erpc.call(peer, Process, :info, [pid, :priority]) == {:priority, :high},
            do: pid
      end

      before = high_priority.()

      {pid, ref} =
        spawn_monitor(fn -> Stampede.run(Observed, vus: 1, duration: 10_000, probe: peer) end)

      Process.sleep(500)
      assert [_agent] = high_priority.() -- before

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      Process.sleep(300)
      assert high_priority.() -- before == []
    end
  end
end
