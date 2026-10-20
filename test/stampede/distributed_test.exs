defmodule Stampede.DistributedTest do
  use ExUnit.Case, async: true

  alias Stampede.Test.{Arriving, Spread}

  @moduletag :distributed

  setup_all do
    {:ok, peer, node} =
      :peer.start(%{
        name: :peer.random_name(~c"stampede-peer"),
        host: ~c"127.0.0.1",
        longnames: true
      })

    :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
    on_exit(fn -> :peer.stop(peer) end)
    %{peer: node}
  end

  test "splits VUs between nodes and merges their metrics", %{peer: peer} do
    result = Stampede.run(Spread, vus: 4, duration: 1_000, nodes: [node(), peer])

    assert result.errors == []
    assert result.metrics["on.#{node()}"].count > 0
    assert result.metrics["on.#{peer}"].count > 0

    vus = for "vu." <> id <- Map.keys(result.metrics), do: String.to_integer(id)
    assert Enum.sort(vus) == [1, 2, 3, 4]

    # Each VU may be stopped between counting an iteration and joining.
    iterations = result.metrics["on.#{node()}"].count + result.metrics["on.#{peer}"].count
    assert result.metrics["channel.join"].count in (iterations - 4)..iterations

    assert [%{vus: 4} | _rest] = result.timeline
  end

  test "splits rates between nodes", %{peer: peer} do
    result = Stampede.run(Arriving, rate: 40, duration: 1_000, nodes: [node(), peer])

    assert result.metrics["iteration"].count in 36..40
  end

  @tag :tmp_dir
  test "mix stampede.run loads the scenarios on --nodes", %{peer: peer, tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "spread.exs")

    File.write!(path, """
    defmodule Stampede.DistributedTest.FromFile do
      use Stampede.Scenario

      @impl true
      def run(_vu) do
        Stampede.increment("on.\#{node()}")
        Process.sleep(10)
      end
    end
    """)

    out = Path.join(tmp_dir, "results.json")

    ExUnit.CaptureIO.capture_io(fn ->
      args = [path, "--vus", "2", "--duration", "300ms", "--nodes", "#{peer}", "--out", out]
      Mix.Tasks.Stampede.Run.run(args)
    end)

    [%{"metrics" => metrics}] = out |> File.read!() |> JSON.decode!()
    assert metrics["on.#{node()}"]["count"] > 0
    assert metrics["on.#{peer}"]["count"] > 0
  end

  test "raises for nodes it cannot reach" do
    assert_raise ArgumentError, ~r/could not connect to node :"nobody@127.0.0.1"/, fn ->
      Stampede.run(Spread, vus: 1, duration: 100, nodes: [node(), :"nobody@127.0.0.1"])
    end
  end

  test "raises for scenarios other nodes cannot load", %{peer: peer} do
    [{scenario, _binary}] =
      Code.compile_string("""
      defmodule Stampede.DistributedTest.InMemory do
        use Stampede.Scenario
        def run(_vu), do: :ok
      end
      """)

    assert_raise ArgumentError, ~r/InMemory is not available on/, fn ->
      Stampede.run(scenario, vus: 1, duration: 100, nodes: [node(), peer])
    end
  end
end
