defmodule Stampede.DashboardTest do
  # The dashboard shows every run on this node, so no other test may run
  # scenarios at the same time.
  use ExUnit.Case, async: false

  alias Stampede.Dashboard
  alias Stampede.Test.Observed

  setup do
    {:ok, dashboard} = Dashboard.start(port: 0)
    on_exit(fn -> if Process.alive?(dashboard), do: Dashboard.stop(dashboard) end)
    %{dashboard: dashboard, url: Dashboard.url(dashboard)}
  end

  defp get!(url) do
    {:ok, response} = Stampede.HTTP.get(url)
    response
  end

  defp version(response) do
    {"x-version", version} = List.keyfind(response.headers, "x-version", 0)
    version
  end

  # Waits until the dashboard's runs match `pattern`, to follow a run.
  defp await_runs!(url, pattern, attempts \\ 50) do
    body = get!(url <> "/runs").body

    cond do
      body =~ pattern -> body
      attempts == 0 -> flunk("expected the runs to match #{inspect(pattern)}, got: #{body}")
      true -> Process.sleep(50) && await_runs!(url, pattern, attempts - 1)
    end
  end

  test "serves a page that waits for runs", %{url: url} do
    assert url =~ ~r"^http://127.0.0.1:\d+$"

    page = get!(url <> "/")
    assert page.status == 200
    assert page.body =~ "<title>Stampede dashboard</title>"
    assert page.body =~ "Waiting for a run to start."
    assert page.body =~ ~s(<div id="runs" data-version="0">)

    assert get!(url <> "/missing").status == 404
  end

  test "shows runs while they go and once they are over", %{url: url} do
    task = Task.async(fn -> Stampede.run(Observed, vus: 2, duration: 2_000) end)

    running = await_runs!(url, "1.0s of 2.0s")
    assert running =~ "<h2>Stampede.Test.Observed</h2>"
    assert running =~ ~s(<span class="status running">Running</span>)
    assert running =~ "The last second"
    assert running =~ ~s(aria-label="VUs")

    Task.await(task)
    done = await_runs!(url, "Ran for")
    refute done =~ "Running"

    response = get!(url <> "/runs")
    assert get!(url <> "/runs?version=" <> version(response)).status == 204
  end

  test "shows runs that run at the same time", %{url: url} do
    Stampede.run_parallel([Observed, Stampede.Test.Checking], vus: 1, duration: 200)

    runs = await_runs!(url, "Stampede.Test.Checking")
    assert runs =~ "Stampede.Test.Observed"
    assert [_, _] = Regex.scan(~r/Ran for/, runs)
  end

  test "shows runs that stopped halfway", %{url: url} do
    {pid, ref} = spawn_monitor(fn -> Stampede.run(Observed, vus: 1, duration: 10_000) end)
    await_runs!(url, "Running")

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert await_runs!(url, "Stopped") =~ "Stampede.Test.Observed"
  end

  test "stop/1 waits for an open page to show the last results", %{dashboard: dashboard} = ctx do
    get!(ctx.url <> "/")
    Stampede.run(Observed, vus: 1, duration: 100)

    task = Task.async(fn -> Dashboard.stop(dashboard) end)
    Process.sleep(100)
    assert Process.alive?(dashboard)

    assert get!(ctx.url <> "/runs").body =~ "Ran for"
    assert Task.await(task) == :ok
    refute Process.alive?(dashboard)
    assert {:error, _reason} = Stampede.HTTP.get(ctx.url <> "/")
  end

  defmodule Chatting do
    use Stampede.Scenario

    @impl true
    def run(_vu) do
      Stampede.LLM.chat(Stampede.TestEndpoint.page_url("/v1"),
        model: "mock",
        messages: [],
        max_tokens: 3
      )
    end
  end

  test "shows tokens while a run chats with a model server", %{url: url} do
    task = Task.async(fn -> Stampede.run(Chatting, vus: 2, duration: 2_500) end)

    assert await_runs!(url, "TTFT p95") =~ "Tokens per second"
    Task.await(task)
  end

  test "serves finished runs as the HTML report and the JSON", %{url: url} do
    Stampede.run(Observed, vus: 1, duration: 200)
    runs = await_runs!(url, "Ran for")

    [_match, id] = Regex.run(~r{href="runs/(\d+)/report\.html" download}, runs)
    assert runs =~ ~s(href="runs/#{id}/results.json" download)

    report = get!(url <> "/runs/#{id}/report.html")
    assert report.status == 200
    assert report.body =~ "<title>Stampede report</title>"

    assert {"content-disposition", ~s(attachment; filename="stampede-#{id}-report.html")} in report.headers

    json = get!(url <> "/runs/#{id}/results.json")
    assert %{"scenario" => "Stampede.Test.Observed"} = JSON.decode!(json.body)

    assert get!(url <> "/runs/999/report.html").status == 404
    assert get!(url <> "/runs/#{id}/other.txt").status == 404
  end

  test "stop/1 returns at once when no page is open", %{dashboard: dashboard} do
    Stampede.run(Observed, vus: 1, duration: 100)

    {microseconds, :ok} = :timer.tc(fn -> Dashboard.stop(dashboard) end)
    assert microseconds < 500_000
  end

  test "start/1 returns an error when the port is taken", %{url: url} do
    port = url |> URI.parse() |> Map.fetch!(:port)
    assert {:error, :eaddrinuse} = Dashboard.start(port: port)
  end
end
