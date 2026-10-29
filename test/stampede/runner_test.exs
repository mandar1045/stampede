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

  test "warns when a node can't hold as many VUs as the plan may need" do
    %{processes: processes, files: files} = Stampede.Runner.limits()
    assert processes > 0 and files > 0

    # A rate plan only starts the VUs it needs, so this runs a single one.
    vus = max(processes, files)
    opts = [rate: 1, duration: 100, max_vus: vus]
    warning = ExUnit.CaptureIO.capture_io(:stderr, fn -> Stampede.run(Observed, opts) end)

    assert warning =~ "Stampede.Test.Observed can run up to #{format(vus)} VUs on #{node()}"
    assert warning =~ "#{format(processes)} processes and #{format(files)} open files"
    assert warning =~ ~s(--erl "+P 4000000" and ulimit -n)

    assert ExUnit.CaptureIO.capture_io(:stderr, fn -> Stampede.run(Observed, duration: 100) end) ==
             ""
  end

  defp format(number), do: Stampede.Reporter.amount(number, :vus)

  defmodule AlwaysFailing do
    use Stampede.Scenario

    @impl true
    def run(_vu), do: raise("down")
  end

  test "waits longer after each failure in a row before trying again" do
    result = Stampede.run(AlwaysFailing, vus: 1, duration: 2_000)

    # Tries at 0, 100, 250, 450, 700 and 1,200ms, then waits a second.
    assert result.metrics["iteration.errors"].count in 5..7
  end

  defmodule Short do
    use Stampede.Scenario

    @impl true
    def options, do: [vus: 1, duration: 300]

    @impl true
    def run(_vu), do: Process.sleep(10)
  end

  defmodule Long do
    use Stampede.Scenario

    @impl true
    def options, do: [vus: 2, duration: 600, thresholds: [{"iteration", count: 0}]]

    @impl true
    def run(_vu), do: Process.sleep(10)
  end

  describe "run_parallel/2" do
    test "runs scenarios at the same time, each with its own options" do
      started_at = System.monotonic_time(:millisecond)
      assert [short, long] = Stampede.run_parallel([Short, Long])

      assert System.monotonic_time(:millisecond) - started_at < 850
      assert {short.scenario, long.scenario} == {Short, Long}
      assert short.duration in 300..450
      assert long.duration in 600..750
      assert short.passed?
      refute long.passed?
      assert long.timeline |> Enum.map(& &1.vus) |> Enum.max() == 2
    end

    test "gives its options to every scenario" do
      assert [short, long] = Stampede.run_parallel([Short, Long], duration: 200)

      assert short.duration in 200..350
      assert long.duration in 200..350
    end

    test "checks every scenario before starting any" do
      assert_raise ArgumentError, ~r/to implement Stampede.Scenario/, fn ->
        Stampede.run_parallel([Short, String])
      end

      assert Process.info(self(), :messages) == {:messages, []}

      assert_raise ArgumentError, ~r/non-empty list of scenarios/, fn ->
        Stampede.run_parallel([])
      end
    end
  end
end
