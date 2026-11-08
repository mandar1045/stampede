if Code.ensure_loaded?(Phoenix.LiveDashboard.PageBuilder) do
  defmodule Stampede.LiveDashboard do
    @moduledoc """
    A page for Phoenix LiveDashboard that shows load tests while they run.

    Add it to the `live_dashboard` route of the app you load test:

        live_dashboard "/dashboard",
          additional_pages: [stampede: Stampede.LiveDashboard]

    The dashboard gets a Stampede tab. It shows the runs that probe the app,
    so you can watch a load test next to the dashboard's processes, ETS
    tables and metrics. A run probes the app with `--probe`, from another
    machine or from a terminal next to the app:

        $ elixir --name loader@127.0.0.1 --cookie <the app's cookie> \\
            -S mix stampede.run loadtest/lobby.exs --probe app@127.0.0.1

    It also shows runs started on the app's own node, such as from IEx.

    The tab lists the last 20 runs, newest first, and updates every second.
    It shows one of them at a time, the newest by default: while it runs, its
    VUs, latencies and the app's own numbers so far, and once it's over, the
    same results as the HTML report.

    The app needs Stampede as a dependency in the environments it runs the
    dashboard in, such as `only: [:dev, :test]`. The page is there whenever
    the app has Phoenix LiveDashboard. With the dashboard's node selector, it
    shows the runs of another node of the app instead, if that node has
    Stampede too.
    """

    use Phoenix.LiveDashboard.PageBuilder, refresher?: false

    alias Stampede.{Dashboard, Reporter, Result}

    @tick 1_000

    @impl true
    def menu_link(_session, _capabilities), do: {:ok, "Stampede"}

    @impl true
    def mount(_params, _session, socket) do
      if connected?(socket), do: tick()

      {:ok,
       assign(socket, runs: [], version: nil, error: nil, selected: nil, shown: nil, html: nil)}
    end

    @impl true
    # The run comes from the URL itself, as the params only have the query
    # when the endpoint parses it.
    def handle_params(_params, uri, socket) do
      query = URI.decode_query(URI.parse(uri).query || "")

      selected =
        case Integer.parse(query["run"] || "") do
          {id, ""} -> id
          _other -> nil
        end

      {:noreply, socket |> assign(selected: selected) |> load(true)}
    end

    @impl true
    def handle_info({__MODULE__, :tick}, socket) do
      tick()
      {:noreply, load(socket, false)}
    end

    def handle_info(_message, socket), do: {:noreply, socket}

    defp tick, do: Process.send_after(self(), {__MODULE__, :tick}, @tick)

    # The runs come from the shared dashboard of the node the page shows, and
    # only when they changed since the last time.
    defp load(socket, force?) do
      version = if force?, do: nil, else: socket.assigns.version

      case fetch(socket.assigns.page.node, version) do
        :unchanged ->
          socket

        {:ok, runs, version} ->
          socket |> assign(runs: runs, version: version, error: nil) |> show()

        {:error, error} ->
          assign(socket, runs: [], version: nil, error: error, html: nil)
      end
    end

    defp fetch(node, version) do
      case Dashboard.runs(node, version) do
        :unchanged -> :unchanged
        {runs, version} -> {:ok, runs, version}
      end
    catch
      _kind, _reason ->
        {:error, "Stampede isn't running on #{node}, so there are no runs to show."}
    end

    # Rendering a run that's over gives the same page every time, so it's
    # rendered once.
    defp show(socket) do
      %{runs: runs, selected: selected, shown: shown} = socket.assigns
      run = Enum.find(runs, &(&1.id == selected)) || List.first(runs)

      case run do
        nil ->
          assign(socket, html: nil, shown: nil)

        %{id: id, status: :done} when shown == {id, :done} ->
          socket

        %{id: id, status: status} ->
          assign(socket, html: render_run(run), shown: {id, status})
      end
    end

    defp render_run(run) do
      Reporter.HTML.embedded(run)
    rescue
      # The run came from a load test with another version of Stampede.
      _error ->
        ~s(<p class="meta">This run came from a different version of Stampede, ) <>
          "so it can't be shown here.</p>"
    end

    @impl true
    def render(assigns) do
      ~H"""
      <style nonce={@csp_nonces[:style]}><%= Phoenix.HTML.raw(Reporter.HTML.embedded_css()) %></style>
      <div :if={@error} class="card mb-4">
        <div class="card-body"><%= @error %></div>
      </div>
      <div :if={!@error and @runs == []} class="card mb-4">
        <div class="card-body">
          No runs yet. Start a load test with <code>--probe <%= @page.node %></code>,
          and it shows here while it runs.
        </div>
      </div>
      <div :if={@runs != []} class="card mb-4">
        <div class="card-body p-0">
          <table class="table table-hover mb-0" id="stampede-runs">
            <thead>
              <tr>
                <th class="pl-4">Run</th>
                <th>Scenario</th>
                <th>Status</th>
                <th class="text-right pr-4">Duration</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={run <- @runs} class={if shown?(run, @shown), do: "table-active"}>
                <td class="pl-4">
                  <.link patch={live_dashboard_path(@socket, @page, run: run.id)}>#<%= run.id %></.link>
                </td>
                <td><code><%= inspect(run.scenario) %></code></td>
                <td><%= status(run) %></td>
                <td class="text-right pr-4"><%= duration(run) %></td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
      <div :if={@html} class="card mb-4">
        <div class="card-body stampede" id="stampede-run">
          <%= Phoenix.HTML.raw(@html) %>
        </div>
      </div>
      """
    end

    defp shown?(%{id: id}, {id, _status}), do: true
    defp shown?(_run, _shown), do: false

    defp status(%{status: :running}), do: "Running"
    defp status(%{status: :stopped}), do: "Stopped"
    defp status(%{result: %Result{thresholds: []}}), do: "Done"
    defp status(%{result: %Result{passed?: true}}), do: "Passed"
    defp status(%{result: %Result{passed?: false}}), do: "Failed"

    defp duration(%{result: %Result{duration: duration}}), do: Reporter.seconds(duration)

    defp duration(%{timeline: timeline}) do
      case List.last(timeline) do
        nil -> "–"
        point -> Reporter.seconds(point.at)
      end
    end
  end
end
