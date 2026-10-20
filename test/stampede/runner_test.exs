defmodule Stampede.RunnerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  defmodule Lobby do
    use Stampede.Scenario

    @impl true
    def options, do: [vus: 2, duration: 300]

    @impl true
    def run(_vu) do
      {:ok, socket} = Stampede.Channels.connect(Stampede.TestEndpoint.socket_url())
      {:ok, _reply} = Stampede.Channels.join(socket, "room:lobby")
      {:ok, _reply} = Stampede.Channels.push(socket, "room:lobby", "ping")
      Process.sleep(10)
    end
  end

  defmodule Failing do
    use Stampede.Scenario

    @impl true
    def run(%{iteration: 0}), do: raise("boom")
    def run(_vu), do: Process.sleep(10)
  end

  defmodule Custom do
    use Stampede.Scenario

    @impl true
    def setup(opts), do: %{vus: opts[:vus]}

    @impl true
    def run(vu) do
      Stampede.increment("seen.#{vu.id}")
      Stampede.increment("setup.#{vu.data.vus}")
      Stampede.measure("nap", fn -> Process.sleep(5) end)
      Stampede.record("server", 7)
    end
  end

  defmodule Reconnecting do
    use Stampede.Scenario

    @impl true
    def setup(_opts), do: self()

    @impl true
    def run(vu) do
      if previous = Process.get(:socket) do
        Stampede.increment(if Process.alive?(previous), do: "leaked", else: "closed")
      end

      {:ok, socket} = Stampede.Channels.connect(Stampede.TestEndpoint.socket_url())
      Process.put(:socket, socket)
      send(vu.data, {:iteration, self(), socket})
      Process.sleep(10)
    end
  end

  defmodule Crashing do
    use Stampede.Scenario

    @impl true
    def run(%{id: 1, iteration: 0}) do
      spawn_link(fn -> exit(:boom) end)
      Process.sleep(:infinity)
    end

    def run(vu), do: Stampede.increment("ran.#{vu.id}")
  end

  test "records the built-in metrics" do
    result = Stampede.run(Lobby)

    assert result.scenario == Lobby
    assert result.duration >= 300
    assert result.passed?
    assert result.errors == []
    assert %{type: :timing, count: iterations} = result.metrics["iteration"]
    assert iterations > 2

    for name <- ["ws.connect", "channel.join", "channel.push"] do
      assert %{type: :timing, count: count, p95: p95} = result.metrics[name]
      assert count >= iterations
      assert p95 > 0
    end
  end

  test "evaluates thresholds" do
    result =
      Stampede.run(Lobby, thresholds: [{"channel.join", p95: 60_000}, {"channel.push", count: 0}])

    refute result.passed?

    assert [
             %{metric: "channel.join", stat: :p95, limit: 60_000, passed?: true},
             %{metric: "channel.push", stat: :count, limit: 0, passed?: false}
           ] = result.thresholds
  end

  test "counts iterations that fail and keeps going" do
    result = Stampede.run(Failing, vus: 2, duration: 300)

    assert result.metrics["iteration.errors"].count == 2
    assert result.metrics["iteration"].count > 0
    assert [%{message: "** (RuntimeError) boom", count: 2}] = result.errors
  end

  test "moves VUs through the stages" do
    result = Stampede.run(Custom, stages: [{100, 3}, {100, 3}, {100, 0}])

    seen = for "seen." <> id <- Map.keys(result.metrics), do: String.to_integer(id)
    assert Enum.sort(seen) == [1, 2, 3]
  end

  test "gives setup data to VUs and records custom metrics" do
    result = Stampede.run(Custom, vus: 1, duration: 100)

    assert result.metrics["setup.1"].count > 0
    assert result.metrics["nap"].p50 >= 5
    assert_in_delta result.metrics["server"].max, 7, 0.1
  end

  test "closes sockets after every iteration and stops VUs at the end" do
    result = Stampede.run(Reconnecting, vus: 2, duration: 200)

    assert result.metrics["closed"].count > 0
    refute Map.has_key?(result.metrics, "leaked")

    for {:iteration, vu, socket} <- Process.info(self(), :messages) |> elem(1) do
      refute Process.alive?(vu)
      ref = Process.monitor(socket)
      assert_receive {:DOWN, ^ref, :process, ^socket, _reason}
    end
  end

  test "replaces VUs that crash" do
    result = Stampede.run(Crashing, vus: 1, duration: 300)

    assert result.metrics["vu.crashes"].count == 1
    assert result.metrics["ran.2"].count > 0
  end

  test "prints progress" do
    output = capture_io(fn -> Stampede.run(Custom, vus: 1, duration: 1_100, progress: true) end)

    assert output =~ ~r/1\.\ds  vus: 1  iterations: \d+  errors: 0/
  end

  test "raises on invalid options" do
    assert_raise ArgumentError, ~r/unknown keys \[:vu\]/, fn -> Stampede.run(Lobby, vu: 1) end
    assert_raise ArgumentError, ~r/to implement Stampede.Scenario/, fn -> Stampede.run(String) end
  end
end
