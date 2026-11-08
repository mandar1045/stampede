defmodule Stampede.LiveDashboardTest do
  # The page shows every run on this node, so no other test may run
  # scenarios at the same time.
  use ExUnit.Case, async: false

  alias Stampede.{Dashboard, LiveView}
  alias Stampede.Test.Observed

  setup do
    stop_shared()
    on_exit(&stop_shared/0)
  end

  # Each test starts with no runs, as an app that just started.
  defp stop_shared do
    if pid = Process.whereis(Dashboard), do: GenServer.stop(pid)
  end

  defp url(path), do: Stampede.TestEndpoint.page_url(path)

  defp get!(path) do
    {:ok, response} = Stampede.HTTP.get(url(path))
    assert response.status == 200
    response.body
  end

  # Every string in a LiveView diff, to look for text in it.
  defp text(diff) when is_map(diff), do: diff |> Map.values() |> Enum.map_join(" ", &text/1)
  defp text(diff) when is_list(diff), do: Enum.map_join(diff, " ", &text/1)
  defp text(diff) when is_binary(diff), do: diff
  defp text(_diff), do: ""

  defp await_runs!(pattern, attempts \\ 50) do
    {runs, _version} = Dashboard.runs(node())

    cond do
      Enum.any?(runs, &match?(^pattern, &1.status)) -> runs
      attempts == 0 -> flunk("expected a run that's #{pattern}, got: #{inspect(runs)}")
      true -> Process.sleep(50) && await_runs!(pattern, attempts - 1)
    end
  end

  test "adds a Stampede page to LiveDashboard, which waits for runs" do
    page = get!("/dashboard/stampede")
    assert page =~ ~s(<div class="menu-item active">Stampede</div>)
    refute page =~ "Update every"
    assert page =~ "No runs yet."
    assert page =~ "--probe #{node()}"
    refute page =~ ~s(id="stampede-runs")
  end

  test "shows a run while it goes, and once it's over" do
    {:ok, view} = LiveView.connect(url("/dashboard/stampede"))
    task = Task.async(fn -> Stampede.run(Observed, vus: 2, duration: 2_000) end)

    {:ok, diff} = LiveView.await(view, match: &(text(&1) =~ "Running"), timeout: 5_000)
    assert text(diff) =~ "Stampede.Test.Observed"

    result = Task.await(task)
    {:ok, _diff} = LiveView.await(view, match: &(text(&1) =~ "Ran for"), timeout: 5_000)
    LiveView.close(view)

    page = get!("/dashboard/stampede")
    assert page =~ ~s(<table class="table table-hover mb-0" id="stampede-runs">)
    assert page =~ ~s(<td><code>Stampede.Test.Observed</code></td>)
    assert page =~ "<td>Done</td>"
    assert page =~ Stampede.Reporter.seconds(result.duration)
    assert page =~ ~s(<div class="card-body stampede" id="stampede-run">)
    assert page =~ ~s(<div class="tiles">)
    assert page =~ ".stampede .tile"
    refute page =~ "report.html"
  end

  test "shows the run it's asked for, and the newest by default" do
    # Runs show from the first time the page is opened.
    get!("/dashboard/stampede")
    Stampede.run(Observed, vus: 1, duration: 200, thresholds: [{"iteration", p95: 1}])
    Stampede.run(Observed, vus: 1, duration: 200)
    await_runs!(:done)

    newest = get!("/dashboard/stampede")
    assert newest =~ "<td>Failed</td>"
    assert newest =~ "<td>Done</td>"
    assert newest =~ ~s(<section id="run-2">)

    first = get!("/dashboard/stampede?run=1")
    assert first =~ ~s(<section id="run-1">)
    assert first =~ ~s(<span class="status failed">Failed</span>)

    assert get!("/dashboard/stampede?run=99") =~ ~s(<section id="run-2">)
  end

  test "keeps the last 20 runs, forgetting the oldest" do
    dashboard = Dashboard.shared()
    assert Dashboard.shared() == dashboard

    for _run <- 1..22 do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      result = %Stampede.Result{scenario: Observed, duration: 100}
      send(dashboard, {:event, pid, [:stampede, :run, :stop], %{}, %{result: result}})
    end

    {runs, _version} = Dashboard.runs(node())
    assert length(runs) == 20
    assert Enum.all?(runs, &(&1.status == :done))
    assert runs |> Enum.map(& &1.id) |> Enum.min() > 1
  end

  test "picks up a run that started before it did" do
    task = Task.async(fn -> Stampede.run(Observed, vus: 1, duration: 2_000) end)
    Process.sleep(700)

    [run] = await_runs!(:running)
    assert run.planned == 0
    assert get!("/dashboard/stampede") =~ "so far"

    Task.await(task)
    [run] = await_runs!(:done)
    assert run.result.duration >= 2_000
  end

  describe "with the app on another node" do
    @describetag :distributed

    setup do
      {:ok, peer, node} =
        :peer.start(%{
          name: :peer.random_name(~c"stampede-app"),
          host: ~c"127.0.0.1",
          longnames: true
        })

      # Elixir, which LiveDashboard needs on the nodes it shows, but not
      # Stampede, until a test adds it.
      :ok = :erpc.call(node, :code, :add_paths, [[:code.lib_dir(:elixir) ++ ~c"/ebin"]])

      on_exit(fn -> :peer.stop(peer) end)
      %{app: node}
    end

    # An app with Stampede and LiveDashboard among its dependencies.
    defp with_stampede(node) do
      :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])

      for app <- [:elixir, :telemetry],
          do: {:ok, _apps} = :erpc.call(node, :application, :ensure_all_started, [app])
    end

    test "shows a run that probes the app on the app's dashboard", %{app: app} do
      with_stampede(app)
      task = Task.async(fn -> Stampede.run(Observed, vus: 1, duration: 2_000, probe: app) end)

      [running] = await_remote!(app, :running)
      assert running.scenario == Observed
      assert running.planned == 2_000

      result = Task.await(task)
      [done] = await_remote!(app, :done)
      assert done.result.duration == result.duration
      assert done.result.server.nodes == [Atom.to_string(app)]

      # This node shows nothing, as it never opened the page.
      assert Process.whereis(Dashboard) == nil

      page = get!("/dashboard/#{app}/stampede")
      assert page =~ ~s(<td><code>Stampede.Test.Observed</code></td>)
      assert page =~ "<td>Done</td>"
    end

    test "says when the node it shows has no Stampede", %{app: app} do
      assert get!("/dashboard/#{app}/stampede") =~ "Stampede isn&#39;t running on #{app}"
    end

    test "a run that probes an app without the page still runs", %{app: app} do
      result = Stampede.run(Observed, vus: 1, duration: 500, probe: app)
      assert result.server.nodes == [Atom.to_string(app)]
      assert :erpc.call(app, Process, :whereis, [Dashboard]) == nil
    end

    defp await_remote!(node, status, attempts \\ 50) do
      {runs, _version} = Dashboard.runs(node)

      cond do
        Enum.any?(runs, &(&1.status == status)) -> runs
        attempts == 0 -> flunk("expected a run that's #{status}, got: #{inspect(runs)}")
        true -> Process.sleep(50) && await_remote!(node, status, attempts - 1)
      end
    end
  end
end
