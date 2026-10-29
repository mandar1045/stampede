defmodule Stampede.Dashboard do
  @moduledoc """
  A web page that shows load tests while they run.

      $ mix stampede.run loadtest/lobby.exs --dashboard
      Dashboard at http://127.0.0.1:4040

  Or from code:

      {:ok, dashboard} = Stampede.Dashboard.start(port: 4040)
      IO.puts("Dashboard at " <> Stampede.Dashboard.url(dashboard))
      Stampede.run(MyApp.Load.Lobby)
      Stampede.Dashboard.stop(dashboard)

  The page lists every run started on this node since the dashboard
  started, newest first, and updates every second. While a run goes, it
  charts the VUs, iterations and latencies so far, with a table of the last
  second. Once the run is over, it shows the same results as the HTML report.

  It follows runs through the telemetry events listed in `Stampede`, so runs
  spread over several nodes and runs of `Stampede.run_parallel/2` show up
  too, as long as the dashboard is on the node that started them.
  """

  use GenServer

  alias Stampede.{Plan, Reporter, Result}

  @events [[:stampede, :run, :start], [:stampede, :run, :interval], [:stampede, :run, :stop]]

  # How long stop/1 waits for an open page to show the last results.
  @stop_wait 2_000

  @doc """
  Starts a dashboard and the web server that serves it.

  The process is not linked to the caller, so that a problem with the
  dashboard never stops a load test.

  ## Options

    * `:port` - the port to listen on, `4040` by default, or `0` for any
      free port
    * `:ip` - the address to listen on, `{127, 0, 0, 1}` by default, so
      that only this machine can open the page
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts \\ []) do
    opts = Keyword.validate!(opts, port: 4040, ip: {127, 0, 0, 1})
    GenServer.start(__MODULE__, opts)
  end

  @doc """
  Returns the URL of the dashboard's page.
  """
  @spec url(pid()) :: String.t()
  def url(dashboard), do: GenServer.call(dashboard, :url)

  @doc """
  Stops the dashboard.

  When a page has the dashboard open, it waits up to two seconds for the
  page to show the latest results first.
  """
  @spec stop(pid()) :: :ok
  def stop(dashboard), do: GenServer.call(dashboard, :stop, @stop_wait + 1_000)

  @doc false
  def handle_event(event, measurements, metadata, dashboard) do
    send(dashboard, {:event, self(), event, measurements, metadata})
  end

  @impl true
  def init(opts) do
    listen_opts = [:binary, ip: opts[:ip], packet: :http_bin, active: false, reuseaddr: true]

    case :gen_tcp.listen(opts[:port], listen_opts) do
      {:ok, listen} ->
        {:ok, port} = :inet.port(listen)
        dashboard = self()
        spawn_link(fn -> accept(listen, dashboard) end)
        :telemetry.attach_many({__MODULE__, self()}, @events, &__MODULE__.handle_event/4, self())

        {:ok,
         %{
           listen: listen,
           url: "http://#{:inet.ntoa(opts[:ip])}:#{port}",
           runs: %{},
           next_id: 1,
           monitors: %{},
           version: 0,
           shown: nil,
           stopping: nil
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:url, _from, state), do: {:reply, state.url, state}

  def handle_call({:result, id}, _from, state) do
    result =
      case state.runs do
        %{^id => %{result: %Result{} = result}} -> result
        _runs -> nil
      end

    {:reply, result, state}
  end

  def handle_call(:runs, _from, state) do
    runs = state.runs |> Map.values() |> Enum.sort_by(& &1.id, :desc)
    {:reply, {runs, state.version}, state}
  end

  # `shown` is the latest version a page asked for, if a page was opened.
  def handle_call(:stop, from, state) do
    if state.shown in [nil, state.version] do
      {:stop, :normal, :ok, state}
    else
      Process.send_after(self(), :stop, @stop_wait)
      {:noreply, %{state | stopping: from}}
    end
  end

  @impl true
  def handle_cast({:shown, version}, state) do
    state = %{state | shown: max(state.shown || 0, version)}

    if state.stopping && state.shown == state.version do
      GenServer.reply(state.stopping, :ok)
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:event, pid, [:stampede, :run, :start], _measurements, metadata}, state) do
    %{scenario: scenario, options: opts} = metadata

    run = %{
      id: state.next_id,
      pid: pid,
      scenario: scenario,
      status: :running,
      planned: planned(opts),
      timeline: [],
      summaries: %{},
      totals: %{},
      result: nil
    }

    monitors =
      if Map.has_key?(state.monitors, pid),
        do: state.monitors,
        else: Map.put(state.monitors, pid, Process.monitor(pid))

    changed(%{
      state
      | runs: Map.put(state.runs, run.id, run),
        next_id: state.next_id + 1,
        monitors: monitors
    })
  end

  def handle_info({:event, pid, [:stampede, :run, :interval], _measurements, metadata}, state) do
    %{interval: point} = metadata

    update_running(state, pid, fn run ->
      totals =
        for {name, %{count: count}} <- point.metrics, reduce: run.totals do
          totals -> Map.update(totals, name, count, &(&1 + count))
        end

      %{
        run
        | timeline: run.timeline ++ [point],
          summaries: Map.merge(run.summaries, point.metrics),
          totals: totals
      }
    end)
  end

  def handle_info({:event, pid, [:stampede, :run, :stop], _measurements, metadata}, state) do
    %{result: %Result{} = result} = metadata
    update_running(state, pid, &%{&1 | status: :done, result: result})
  end

  # A process that stops in the middle of a run took its run with it.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = %{state | monitors: Map.delete(state.monitors, pid)}
    update_running(state, pid, &%{&1 | status: :stopped})
  end

  def handle_info(:stop, state) do
    GenServer.reply(state.stopping, :ok)
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach({__MODULE__, self()})
    :gen_tcp.close(state.listen)
  end

  defp planned(opts) do
    opts |> Plan.from_options() |> Plan.duration()
  rescue
    _error -> 0
  end

  # A process runs one scenario at a time, so its events belong to the run
  # it started last that is still going.
  defp update_running(state, pid, fun) do
    running = for {id, %{pid: ^pid, status: :running}} <- state.runs, do: id

    case running do
      [] -> {:noreply, state}
      ids -> changed(%{state | runs: Map.update!(state.runs, Enum.max(ids), fun)})
    end
  end

  defp changed(state), do: {:noreply, %{state | version: state.version + 1}}

  ## Web server

  defp accept(listen, dashboard) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        pid =
          spawn(fn ->
            receive do
              :serve -> serve(socket, dashboard)
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, :serve)
        accept(listen, dashboard)

      {:error, _reason} ->
        :ok
    end
  end

  defp serve(socket, dashboard) do
    response =
      with {:ok, {:http_request, :GET, {:abs_path, target}, _version}} <-
             :gen_tcp.recv(socket, 0, 5_000),
           :ok <- skip_headers(socket) do
        %URI{path: path, query: query} = URI.parse(target)
        respond(path, URI.decode_query(query || ""), dashboard)
      else
        _other -> {404, [], "Not found"}
      end

    {status, headers, body} = response
    :gen_tcp.send(socket, http_response(status, headers, body))
    :gen_tcp.close(socket)
  catch
    # The dashboard stopped while it was being asked.
    :exit, _reason -> :gen_tcp.close(socket)
  end

  # The request is read to the end, so that closing the socket does not
  # reset the connection before the browser reads the response.
  defp skip_headers(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, :http_eoh} -> :ok
      {:ok, {:http_header, _, _, _, _}} -> skip_headers(socket)
      other -> other
    end
  end

  defp respond("/", _params, dashboard) do
    {runs, version} = GenServer.call(dashboard, :runs)
    GenServer.cast(dashboard, {:shown, version})
    {200, [{"content-type", "text/html; charset=utf-8"}], Reporter.HTML.dashboard(runs, version)}
  end

  defp respond("/runs", params, dashboard) do
    {runs, version} = GenServer.call(dashboard, :runs)
    GenServer.cast(dashboard, {:shown, version})

    if params["version"] == Integer.to_string(version) do
      {204, [], ""}
    else
      headers = [
        {"content-type", "text/html; charset=utf-8"},
        {"x-version", Integer.to_string(version)}
      ]

      {200, headers, Reporter.HTML.runs(runs)}
    end
  end

  defp respond("/runs/" <> file, _params, dashboard) do
    with [id, name] <- String.split(file, "/"),
         {id, ""} <- Integer.parse(id),
         {:ok, type, render} <- download(name),
         %Result{} = result <- GenServer.call(dashboard, {:result, id}) do
      filename = "stampede-#{id}-#{name}"

      headers = [
        {"content-type", type},
        {"content-disposition", ~s(attachment; filename="#{filename}")}
      ]

      {200, headers, render.(result)}
    else
      _other -> {404, [], "Not found"}
    end
  end

  defp respond(_path, _params, _dashboard), do: {404, [], "Not found"}

  defp download("report.html"),
    do: {:ok, "text/html; charset=utf-8", &Reporter.to_html/1}

  defp download("results.json"), do: {:ok, "application/json", &Reporter.to_json/1}
  defp download(_name), do: :error

  defp http_response(status, headers, body) do
    reason = %{200 => "OK", 204 => "No Content", 404 => "Not Found"}

    headers = [
      {"content-length", Integer.to_string(IO.iodata_length(body))},
      {"cache-control", "no-store"},
      {"connection", "close"} | headers
    ]

    [
      "HTTP/1.1 #{status} #{reason[status]}\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n",
      body
    ]
  end
end
