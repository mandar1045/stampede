defmodule Stampede.KinoTest do
  # Runs scenarios, which other tests mustn't do at the same time.
  use ExUnit.Case, async: false

  import Kino.Test

  alias Stampede.Kino.SmartCell
  alias Stampede.Test.Observed

  setup :configure_livebook_bridge

  describe "run/2" do
    test "shows the run while it goes, then returns the result" do
      result = Stampede.Kino.run(Observed, vus: 2, duration: 1_500)

      assert %Stampede.Result{scenario: Observed} = result
      assert result.duration >= 1_500

      # A frame with the run in it, cleared at the end for the result.
      assert_output(%{type: :frame, ref: ref, outputs: []})

      assert_receive {:livebook_put_output,
                      %{type: :frame_update, ref: ^ref, update: {:replace, [_live]}}}

      assert_receive {:livebook_put_output,
                      %{type: :frame_update, ref: ^ref, update: {:replace, []}}},
                     1_000
    end

    test "sends the run to the page every second" do
      dashboard = start_dashboard()

      idle = Stampede.Kino.Live.new(dashboard, self())
      assert connect(idle) =~ "Starting the run."

      task = Task.async(fn -> Stampede.run(Observed, vus: 1, duration: 1_500) end)
      live = Stampede.Kino.Live.new(dashboard, task.pid)
      assert await_html(live, "Running") =~ "Stampede.Test.Observed"

      Task.await(task)
      html = await_html(live, "Ran for")
      assert connect(live) == html
    end
  end

  test "shows a result as the report, with the raw struct next to it" do
    result = Stampede.run(Observed, vus: 1, duration: 300)

    assert %{type: :tabs, labels: ["Report", "Raw"], outputs: [report, raw]} =
             Kino.Render.to_livebook(result)

    assert %{type: :js, js_view: %{ref: _ref}} = report
    assert %{type: :terminal_text} = raw
    assert Stampede.Kino.js() =~ "const setupCharts"
    assert Stampede.Kino.js() =~ ".stampede .tile"
  end

  describe "the smart cell" do
    test "is registered for Livebook" do
      assert SmartCell in Application.get_env(:kino, :smart_cell_modules)
    end

    test "starts with an HTTP load test that compiles" do
      {kino, source} = start_smart_cell!(SmartCell, %{})

      assert source =~ ~S|Stampede.HTTP.get("http://localhost:4000/")|
      assert source =~ "stages: [{[second: 10], 10}, {[second: 30], 10}]"
      assert source =~ ~s({"http.request", p95: 500})
      assert Code.string_to_quoted!(source)

      assert %{"kind" => "http", "vus" => 10} = connect(kino)
    end

    test "follows its fields" do
      {kino, _source} = start_smart_cell!(SmartCell, %{})

      push_event(kino, "update", %{"field" => "kind", "value" => "channels"})
      assert_broadcast_event(kino, "update", %{"url" => "ws://localhost:4000/socket"})
      assert_smart_cell_update(kino, %{"kind" => "channels"}, source)
      assert source =~ ~S|Stampede.Channels.join(socket, "room:lobby")|
      assert source =~ ~s({"channel.join", p95: 500})

      push_event(kino, "update", %{"field" => "vus", "value" => "250"})
      assert_smart_cell_update(kino, %{"vus" => 250}, source)
      assert source =~ "{[second: 30], 250}"

      push_event(kino, "update", %{"field" => "probe", "value" => " app@127.0.0.1 "})
      push_event(kino, "update", %{"field" => "cookie", "value" => "secret"})
      assert_smart_cell_update(kino, %{"cookie" => "secret"}, source)
      assert source =~ ~S|Node.set_cookie(:"app@127.0.0.1", :secret)|
      assert source =~ ~s(probe: :"app@127.0.0.1")
      assert Code.string_to_quoted!(source)
    end

    test "keeps a field when its new value doesn't make sense" do
      {kino, _source} = start_smart_cell!(SmartCell, %{})

      push_event(kino, "update", %{"field" => "vus", "value" => "lots"})
      assert_broadcast_event(kino, "update", %{"vus" => 10})

      push_event(kino, "update", %{"field" => "kind", "value" => "smtp"})
      assert_broadcast_event(kino, "update", %{"kind" => "http"})
    end

    test "keeps the host of a URL that isn't a default when the kind changes" do
      {kino, _source} = start_smart_cell!(SmartCell, %{"url" => "https://my.app:4443/posts"})

      push_event(kino, "update", %{"field" => "kind", "value" => "channels"})
      assert_broadcast_event(kino, "update", %{"url" => "wss://my.app:4443/socket"})

      push_event(kino, "update", %{"field" => "kind", "value" => "live"})
      assert_broadcast_event(kino, "update", %{"url" => "https://my.app:4443/"})
    end

    test "keeps a URL that isn't a default when the kind changes" do
      {kino, _source} = start_smart_cell!(SmartCell, %{"url" => "https://example.com/feed"})

      push_event(kino, "update", %{"field" => "kind", "value" => "live"})

      assert_broadcast_event(kino, "update", %{
        "kind" => "live",
        "url" => "https://example.com/feed"
      })
    end

    test "writes code that runs" do
      for {kind, path, metric} <- [
            {"http", "/plain", "http.request"},
            {"live", "/counter", "live.join"}
          ] do
        url = Stampede.TestEndpoint.page_url(path)

        # A module of its own for each, as the code defines it.
        attrs = %{
          "name" => "LoadTest" <> String.capitalize(kind),
          "kind" => kind,
          "url" => url,
          "vus" => 2,
          "ramp" => 0,
          "hold" => 1,
          "pause" => 0
        }

        {_kino, source} = start_smart_cell!(SmartCell, attrs)
        {result, _binding} = Code.eval_string(source)

        assert %Stampede.Result{passed?: true} = result
        assert result.metrics[metric].count > 0
        refute result.metrics["iteration.errors"]
      end
    end
  end

  # The page the live kino sent last, once it has `text`.
  defp await_html(%{ref: ref} = live, text) do
    receive do
      {:runtime_broadcast, "js_live", ^ref, {:event, "html", html, _info}} ->
        if html =~ text, do: html, else: await_html(live, text)
    after
      3_000 -> flunk("expected the page to show #{inspect(text)}")
    end
  end

  defp start_dashboard do
    {:ok, dashboard} = Stampede.Dashboard.start(port: false)
    dashboard
  end
end
