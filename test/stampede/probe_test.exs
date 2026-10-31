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
    result = Stampede.run(Lobby, vus: 2, duration: 1_500, probe: node())

    assert result.metrics["server.channel.join"].count >= 2
    assert result.metrics["server.channel.event"].count >= 2
    assert result.metrics["server.channel.event"].p95 > 0
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
