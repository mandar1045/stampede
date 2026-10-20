defmodule Stampede.RunnerTest do
  use ExUnit.Case, async: true

  alias Stampede.Test.{Crashing, Custom, Failing, Lobby, Observed, Reconnecting}

  test "records the built-in metrics" do
    result = Stampede.run(Lobby)

    assert result.scenario == Lobby
    assert result.duration >= 1_000
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
    result = Stampede.run(Failing, vus: 2, duration: 1_000)

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
    result = Stampede.run(Reconnecting, vus: 2, duration: 1_000)

    assert result.metrics["closed"].count > 0
    refute Map.has_key?(result.metrics, "leaked")

    for {:iteration, vu, socket} <- Process.info(self(), :messages) |> elem(1) do
      refute Process.alive?(vu)
      ref = Process.monitor(socket)
      assert_receive {:DOWN, ^ref, :process, ^socket, _reason}
    end
  end

  test "replaces VUs that crash" do
    result = Stampede.run(Crashing, vus: 1, duration: 1_000)

    assert result.metrics["vu.crashes"].count == 1
    assert result.metrics["ran.2"].count > 0
  end

  test "leaves nothing in the caller's mailbox" do
    Stampede.run(Observed, vus: 2, duration: 300)

    assert Process.info(self(), :messages) == {:messages, []}
  end

  test "raises on invalid options" do
    assert_raise ArgumentError, ~r/unknown keys \[:vu\]/, fn -> Stampede.run(Lobby, vu: 1) end
    assert_raise ArgumentError, ~r/to implement Stampede.Scenario/, fn -> Stampede.run(String) end
  end
end
