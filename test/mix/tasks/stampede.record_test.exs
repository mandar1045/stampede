defmodule Mix.Tasks.Stampede.RecordTest do
  # The task writes to the current directory, which the whole VM shares, and
  # the recorder hears every LiveView on the node.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Stampede.Record

  @moduletag :tmp_dir

  test "raises when nothing was recorded", %{tmp_dir: tmp_dir} do
    assert_raise Mix.Error, ~r/Nothing was recorded/, fn ->
      capture_io([input: "\n"], fn -> File.cd!(tmp_dir, fn -> Record.run(["Empty"]) end) end)
    end
  end

  test "writes what it recorded", %{tmp_dir: tmp_dir} do
    url = Stampede.TestEndpoint.page_url("/counter")

    # The browser: the task waits for Enter while this runs.
    browse = fn ->
      {:ok, view} = Stampede.LiveView.connect(url)
      {:ok, nil} = Stampede.LiveView.click(view, "inc")
      :ok = Stampede.LiveView.close(view)
      Process.sleep(50)
    end

    output =
      capture_io([input: "\n"], fn ->
        File.cd!(tmp_dir, fn -> Record.run(["Checkout"], browse) end)
      end)

    assert output =~ "Recording."
    assert output =~ "Recorded 2 steps"

    scenario = File.read!(Path.join(tmp_dir, "loadtest/checkout.exs"))
    assert scenario =~ ~s(Stampede.LiveView.click(view, "inc"\))
  end

  test "raises on invalid arguments" do
    assert_raise Mix.Error, ~r/Expected a scenario name/, fn -> Record.run([]) end
    assert_raise Mix.Error, ~r/to be a module name/, fn -> Record.run(["not-a-name"]) end
  end
end
