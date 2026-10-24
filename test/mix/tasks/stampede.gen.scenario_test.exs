defmodule Mix.Tasks.Stampede.Gen.ScenarioTest do
  # The task writes to the current directory, which the whole VM shares.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Stampede.Gen.Scenario

  @moduletag :tmp_dir

  # Without the colors Mix adds when the tests run in a terminal.
  defp generate!(tmp_dir, args) do
    capture_io(fn -> File.cd!(tmp_dir, fn -> Scenario.run(args) end) end)
    |> String.replace(~r/\e\[[0-9;]*m/, "")
  end

  # Compiles a generated scenario, and runs it for a moment against the test
  # server to show that it works as generated.
  defp run!(path) do
    contents = File.read!(path)
    assert IO.iodata_to_binary([Code.format_string!(contents), "\n"]) == contents

    [{module, _binary}] = Code.compile_string(contents, path)
    Stampede.run(module, stages: nil, vus: 1, duration: 300)
  end

  test "generates an HTTP scenario named after the application", %{tmp_dir: tmp_dir} do
    url = Stampede.TestEndpoint.page_url("/api/hello")
    output = generate!(tmp_dir, ["Home", "--url", url])

    assert output =~ "creating loadtest/home.exs"
    assert output =~ "mix stampede.run loadtest/home.exs"

    path = Path.join(tmp_dir, "loadtest/home.exs")
    assert File.read!(path) =~ "defmodule Stampede.Load.Home do"

    result = run!(path)
    assert result.errors == []
    assert result.metrics["status is 200"].passed > 0
  end

  test "generates a Channels scenario", %{tmp_dir: tmp_dir} do
    generate!(tmp_dir, ["Lobby", "--channels", "--url", Stampede.TestEndpoint.socket_url()])

    result = run!(Path.join(tmp_dir, "loadtest/lobby.exs"))
    assert result.errors == []
    assert result.metrics["channel.push"].count > 0
  end

  test "generates a LiveView scenario", %{tmp_dir: tmp_dir} do
    url = Stampede.TestEndpoint.page_url("/counter")
    generate!(tmp_dir, ["Shop.Checkout", "--live", "--url", url])

    path = Path.join(tmp_dir, "loadtest/shop/checkout.exs")
    assert File.read!(path) =~ "defmodule Stampede.Load.Shop.Checkout do"

    result = run!(path)
    assert result.errors == []
    assert result.metrics["live.join"].count > 0
  end

  test "generates a WebSocket scenario", %{tmp_dir: tmp_dir} do
    generate!(tmp_dir, ["Feed", "--websocket", "--url", Stampede.TestEndpoint.echo_url()])

    result = run!(Path.join(tmp_dir, "loadtest/feed.exs"))
    assert result.errors == []
    assert result.metrics["ws.messages.sent"].count > 0
  end

  test "overwrites a file with --force", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "loadtest/again.exs")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "old")

    generate!(tmp_dir, ["Again", "--force"])

    assert File.read!(path) =~ "defmodule Stampede.Load.Again do"
  end

  test "raises on invalid arguments" do
    assert_raise Mix.Error, ~r/Expected a scenario name/, fn -> Scenario.run([]) end

    assert_raise Mix.Error, ~r/to be a module name/, fn -> Scenario.run(["my-scenario"]) end

    assert_raise Mix.Error, ~r/only one of --http, --channels/, fn ->
      Scenario.run(["Home", "--live", "--channels"])
    end
  end
end
