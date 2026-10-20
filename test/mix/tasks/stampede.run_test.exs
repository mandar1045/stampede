defmodule Mix.Tasks.Stampede.RunTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  defp write_scenario!(tmp_dir, name, body) do
    path = Path.join(tmp_dir, "#{name}.exs")

    File.write!(path, """
    defmodule Stampede.TaskTest.#{name} do
      use Stampede.Scenario
    #{body}
    end
    """)

    path
  end

  test "runs the scenarios in a file and prints a summary", %{tmp_dir: tmp_dir} do
    path =
      write_scenario!(tmp_dir, "Napping", """
        @impl true
        def run(_vu), do: Process.sleep(10)
      """)

    output =
      capture_io(fn ->
        Mix.Tasks.Stampede.Run.run([path, "--vus", "2", "--duration", "200ms"])
      end)

    assert output =~ "Stampede.TaskTest.Napping ran for 0.2s"
    assert output =~ ~r/iteration\s+\d+/
  end

  test "exits with status 1 when a threshold fails", %{tmp_dir: tmp_dir} do
    path =
      write_scenario!(tmp_dir, "Strict", """
        @impl true
        def options, do: [duration: 100, thresholds: [{"iteration", count: 0}]]

        @impl true
        def run(_vu), do: Process.sleep(10)
      """)

    assert catch_exit(capture_io(fn -> Mix.Tasks.Stampede.Run.run([path]) end)) == {:shutdown, 1}
  end

  test "raises on invalid arguments", %{tmp_dir: tmp_dir} do
    assert_raise Mix.Error, ~r/Expected a scenario file/, fn -> Mix.Tasks.Stampede.Run.run([]) end

    assert_raise Mix.Error, ~r/Expected --duration/, fn ->
      Mix.Tasks.Stampede.Run.run(["scenario.exs", "--duration", "soon"])
    end

    assert_raise Mix.Error, ~r/Could not find scenario file/, fn ->
      Mix.Tasks.Stampede.Run.run([Path.join(tmp_dir, "missing.exs")])
    end

    path = Path.join(tmp_dir, "empty.exs")
    File.write!(path, "defmodule Stampede.TaskTest.Empty do\nend\n")

    assert_raise Mix.Error, ~r/No module in .* implements Stampede.Scenario/, fn ->
      Mix.Tasks.Stampede.Run.run([path])
    end

    assert_raise Mix.Error, ~r/Expected either --vus or --rate/, fn ->
      Mix.Tasks.Stampede.Run.run([path, "--vus", "1", "--rate", "1"])
    end

    assert_raise Mix.Error, ~r/Could not connect to nobody@127.0.0.1|named node/, fn ->
      Mix.Tasks.Stampede.Run.run([path, "--nodes", "nobody@127.0.0.1"])
    end
  end

  test "runs at a rate and writes the results as JSON", %{tmp_dir: tmp_dir} do
    path =
      write_scenario!(tmp_dir, "Steady", """
        @impl true
        def options, do: [vus: 5, duration: 5_000]

        @impl true
        def run(_vu), do: Process.sleep(10)
      """)

    out = Path.join(tmp_dir, "results.json")

    capture_io(fn ->
      Mix.Tasks.Stampede.Run.run([path, "--rate", "20", "--duration", "500ms", "--out", out])
    end)

    assert [%{"scenario" => "Stampede.TaskTest.Steady", "duration" => duration} = result] =
             out |> File.read!() |> JSON.decode!()

    assert duration in 500..600
    assert result["metrics"]["iteration"]["count"] in 8..10
  end
end
