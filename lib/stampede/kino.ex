if Code.ensure_loaded?(Kino) do
  defmodule Stampede.Kino do
    @moduledoc """
    Load tests in Livebook.

    Add Stampede and Kino to a notebook:

        Mix.install([{:stampede, "~> 1.4"}, {:kino, "~> 0.14"}])

    Then pick **Load test** from the **+ Smart** menu. It asks what to load
    test, such as a page, a LiveView, a channel or an AI chat API, and how
    many users to ramp up to, and writes the scenario for you. When the cell
    runs, the run shows in the notebook while it goes: VUs, latencies and,
    with a probe node, the app's own numbers, the same as Stampede's
    dashboard. Once it's over, you get the same results as the HTML report.
    You can turn the cell into code to change the scenario.

    From code, `run/2` does the same for any scenario:

        defmodule LoadTest do
          use Stampede.Scenario

          @impl true
          def run(_vu) do
            {:ok, _response} = Stampede.HTTP.get("http://localhost:4000/")
            Process.sleep(1_000)
          end
        end

        Stampede.Kino.run(LoadTest, vus: 20, duration: [second: 30])

    Livebook shows any `Stampede.Result` as the report, so the result of
    `Stampede.run/2` shows up too, though only once the run is over.

    ## Probing your app

    Give the cell your app's node and cookie, and it watches the app from the
    inside too, as `--probe` does. The notebook's node has to reach the app's.
    Livebook's nodes use short names unless it's started with
    `LIVEBOOK_DISTRIBUTION=name`, so start the app with a short name too:

        $ elixir --sname app --cookie secret -S mix phx.server

    and probe `app@` followed by your machine's host name, as `node()` shows
    it in the app.
    """

    alias Stampede.{Dashboard, Reporter}

    @doc """
    Runs `scenario` with `opts`, as `Stampede.run/2` does, showing the run in
    the notebook while it goes.

    Returns the result, which Livebook shows as the report.
    """
    @spec run(module(), keyword()) :: Stampede.Result.t()
    def run(scenario, opts \\ []) when is_atom(scenario) and is_list(opts) do
      {:ok, dashboard} = Dashboard.start(port: false)
      # Nothing shows once it's cleared, not even a placeholder.
      frame = Kino.Frame.new(placeholder: false)
      Kino.render(frame)
      Kino.Frame.render(frame, Stampede.Kino.Live.new(dashboard, self()))

      try do
        result = Stampede.run(scenario, opts)
        # The result takes the place of the run, as the report.
        Kino.Frame.clear(frame)
        result
      after
        Dashboard.stop(dashboard)
      end
    end

    @doc false
    # The page that shows a run or a result, with the report's styles and
    # tooltips, light only like LiveDashboard's.
    def js(report_css, chart_js) do
      css =
        report_css <>
          """
          .stampede {
            background: var(--page);
            border-radius: 8px;
            padding: 16px;
            font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
          }
          """

      """
      #{chart_js}
      const css = #{JSON.encode!(css)};

      export function init(ctx, html) {
        const style = document.createElement("style");
        style.textContent = css;
        document.head.appendChild(style);

        const root = document.createElement("div");
        root.className = "stampede";
        ctx.root.appendChild(root);

        const show = (html) => {
          root.innerHTML = html;
          setupCharts(root);
        };

        show(html);
        if (ctx.handleEvent) ctx.handleEvent("html", show);
      }
      """
    end
  end

  defmodule Stampede.Kino.Report do
    @moduledoc false

    # A result, as the HTML report shows it.

    use Kino.JS

    def new(%Stampede.Result{} = result) do
      Kino.JS.new(__MODULE__, Stampede.Reporter.HTML.embedded(%{id: nil, result: result}))
    end

    # Calling the report here, not only from js/2, makes this rebuild when the
    # report's styles change.
    asset "main.js" do
      Stampede.Kino.js(Stampede.Reporter.HTML.embedded_css(), Stampede.Reporter.HTML.chart_js())
    end
  end

  defmodule Stampede.Kino.Live do
    @moduledoc false

    # A run while it goes. It asks `dashboard` for the run of `pid` every
    # second, and sends the page again when it changed.

    use Kino.JS
    use Kino.JS.Live

    alias Stampede.Reporter

    @tick 1_000

    def new(dashboard, pid), do: Kino.JS.Live.new(__MODULE__, {dashboard, pid})

    @impl true
    def init({dashboard, pid}, ctx) do
      Process.monitor(dashboard)
      send(self(), :tick)
      html = ~s(<p class="meta">Starting the run.</p>)
      {:ok, assign(ctx, dashboard: dashboard, pid: pid, version: nil, html: html)}
    end

    @impl true
    def handle_connect(ctx), do: {:ok, ctx.assigns.html, ctx}

    @impl true
    def handle_info(:tick, ctx) do
      Process.send_after(self(), :tick, @tick)
      {:noreply, refresh(ctx)}
    end

    # The run is over, and the dashboard went with it.
    def handle_info({:DOWN, _ref, :process, _pid, _reason}, ctx) do
      {:noreply, assign(ctx, dashboard: nil)}
    end

    defp refresh(%{assigns: %{dashboard: nil}} = ctx), do: ctx

    defp refresh(ctx) do
      %{dashboard: dashboard, pid: pid, version: version} = ctx.assigns

      with {runs, version} <- GenServer.call(dashboard, {:runs, version}),
           %{} = run <- Enum.find(runs, &(&1.pid == pid)) do
        html = Reporter.HTML.embedded(run)
        broadcast_event(ctx, "html", html)
        assign(ctx, html: html, version: version)
      else
        _unchanged -> ctx
      end
    catch
      :exit, _reason -> ctx
    end

    # Calling the report here, not only from js/2, makes this rebuild when the
    # report's styles change.
    asset "main.js" do
      Stampede.Kino.js(Stampede.Reporter.HTML.embedded_css(), Stampede.Reporter.HTML.chart_js())
    end
  end

  defimpl Kino.Render, for: Stampede.Result do
    def to_livebook(result) do
      [Report: Stampede.Kino.Report.new(result), Raw: Kino.Inspect.new(result)]
      |> Kino.Layout.tabs()
      |> Kino.Render.to_livebook()
    end
  end
end
