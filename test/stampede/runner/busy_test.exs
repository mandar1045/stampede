defmodule Stampede.Runner.BusyTest do
  # These VUs keep every scheduler busy, which would show up in any other run
  # going on at the same time.
  use ExUnit.Case, async: false

  defmodule Burning do
    use Stampede.Scenario

    @impl true
    def run(_vu), do: Stream.repeatedly(fn -> :rand.uniform() end) |> Stream.run()
  end

  test "ends on time while VUs keep every scheduler busy" do
    vus = System.schedulers_online() * 50

    {microseconds, result} =
      :timer.tc(fn -> Stampede.run(Burning, vus: vus, duration: 1_500) end)

    assert microseconds < 5_000_000
    assert [_ | _] = result.timeline
    assert Enum.max_by(result.timeline, & &1.busy).busy > 0.9
    assert Process.info(self(), :priority) == {:priority, :normal}
  end
end
