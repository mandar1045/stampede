defmodule Stampede.Recorder do
  @moduledoc """
  Records what a person does in a Phoenix app, to turn it into a scenario.

  The easiest way in is `mix stampede.record`. From code:

      {:ok, recorder} = Stampede.Recorder.start()
      # Click through the app in a browser.
      steps = Stampede.Recorder.stop(recorder)
      File.write!("loadtest/checkout.exs", Stampede.Recorder.to_scenario(steps, MyApp.Load.Checkout))

  It runs in the same VM as the app, and records from LiveView's and Phoenix's
  telemetry: pages opened, live navigation, patches, clicks and forms, with the
  time between them as pauses. Plain GET requests are recorded too.

  Fields that look sensitive, such as passwords and tokens, are replaced with
  `"CHANGE_ME"`, so they don't end up in a file you might commit. Other form
  values are kept as they were typed.

  Not recorded yet: file uploads and Channels. Other HTTP requests, such as a
  POST to a sign-in page, show up as comments in the scenario to fill in by
  hand. Pages behind a login need the
  [login guide](login.html).
  """

  use GenServer

  @events [
    [:phoenix, :live_view, :mount, :stop],
    [:phoenix, :live_view, :handle_params, :stop],
    [:phoenix, :live_view, :handle_event, :stop],
    [:phoenix, :live_component, :handle_event, :stop],
    [:phoenix, :router_dispatch, :stop]
  ]

  @sensitive ~r/pass|secret|token|card|cvv|ssn|api.?key/i
  @dropped ~w(_csrf_token _target)
  @placeholder "CHANGE_ME"

  # Pauses shorter than this are the app's own speed, and longer ones are
  # someone getting a coffee.
  @min_pause 100
  @max_pause 30_000
  # An event this close before a page change caused it.
  @caused_by 1_500

  @typedoc "One thing the person did, with `:at` in milliseconds."
  @type step :: map()

  @doc "Starts recording."
  @spec start() :: {:ok, pid()}
  def start, do: GenServer.start(__MODULE__, nil)

  @doc "Stops recording, and returns the steps recorded."
  @spec stop(pid()) :: [step()]
  def stop(recorder), do: GenServer.call(recorder, :stop)

  @doc """
  Writes `steps` as the source code of a scenario named `module`.
  """
  @spec to_scenario([step()], module() | String.t()) :: String.t()
  def to_scenario(steps, module) do
    name = if is_atom(module), do: inspect(module), else: module

    source = """
    defmodule #{name} do
      use Stampede.Scenario

      # Recorded with mix stampede.record. A VU does what you did, with the
      # same pauses. This ramps up to 50 VUs over 30 seconds, holds them for a
      # minute and ramps down.
      @impl true
      def options do
        [
          stages: [{[second: 30], 50}, {[minute: 1], 50}, {[second: 10], 0}],
          thresholds: [{#{inspect(metric(steps))}, p95: 500}, {"iteration.errors", count: 0}]
        ]
      end

      @impl true
      def run(_vu) do
    #{body(steps)}
      end
    end
    """

    IO.iodata_to_binary([Code.format_string!(source), "\n"])
  end

  @impl true
  def init(nil) do
    id = {__MODULE__, self()}
    :telemetry.attach_many(id, @events, &__MODULE__.handle_telemetry/4, self())
    {:ok, %{id: id, raw: []}}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    :telemetry.detach(state.id)
    {:stop, :normal, state.raw |> Enum.reverse() |> Enum.sort_by(& &1.at) |> steps(), state}
  end

  @impl true
  def handle_info({:raw, raw}, state), do: {:noreply, %{state | raw: [raw | state.raw]}}

  @doc false
  def handle_telemetry(event, _measurements, metadata, recorder) do
    case raw(event, metadata) do
      nil -> :ok
      raw -> send(recorder, {:raw, Map.put(raw, :at, System.monotonic_time(:millisecond))})
    end
  end

  # The page and its data are read before a socket connects too, which is the
  # same page again, so only connected root views count.
  defp raw([:phoenix, :live_view, :mount, :stop], %{socket: socket, uri: uri}) do
    if root?(socket) do
      %{kind: :page, transport: socket.transport_pid, root: socket.root_pid, uri: uri}
    end
  end

  defp raw([:phoenix, :live_view, :handle_params, :stop], %{socket: socket, uri: uri}) do
    if root?(socket), do: %{kind: :params, root: socket.root_pid, uri: uri}
  end

  defp raw([:phoenix, :live_view, :handle_event, :stop], metadata) do
    %{socket: socket, event: event, params: params} = metadata

    if root?(socket) do
      %{kind: :event, root: socket.root_pid, event: event, params: params, target: nil}
    end
  end

  defp raw([:phoenix, :live_component, :handle_event, :stop], metadata) do
    %{socket: socket, event: event, params: params} = metadata
    target = socket.assigns.myself.cid
    %{kind: :event, root: socket.root_pid, event: event, params: params, target: target}
  end

  defp raw([:phoenix, :router_dispatch, :stop], %{plug: Phoenix.LiveView.Plug}), do: nil

  defp raw([:phoenix, :router_dispatch, :stop], %{conn: conn}) do
    %{kind: :http, method: conn.method, url: request_url(conn)}
  end

  defp raw(_event, _metadata), do: nil

  defp request_url(conn) do
    url = "#{conn.scheme}://#{conn.host}:#{conn.port}#{conn.request_path}"
    if conn.query_string == "", do: url, else: "#{url}?#{conn.query_string}"
  end

  defp root?(socket) do
    socket.transport_pid != nil and socket.parent_pid == nil
  end

  # Works out what each thing that happened was, from what happened before.
  defp steps(raw) do
    start = %{steps: [], transport: nil, root: nil, uri: nil}

    raw
    |> Enum.reduce(start, &step/2)
    |> Map.fetch!(:steps)
    |> Enum.reverse()
  end

  defp step(%{kind: :page} = raw, state) do
    kind = if raw.transport == state.transport, do: :navigate, else: :open
    state = %{state | transport: raw.transport, root: raw.root, uri: raw.uri}
    add(state, %{kind: kind, url: raw.uri, at: raw.at})
  end

  defp step(%{kind: :params, root: root, uri: uri}, %{root: root, uri: uri} = state), do: state

  defp step(%{kind: :params, root: root} = raw, %{root: root} = state) do
    add(%{state | uri: raw.uri}, %{kind: :patch, url: raw.uri, at: raw.at})
  end

  defp step(%{kind: :event, root: root} = raw, %{root: root} = state) do
    add(state, %{
      kind: event_kind(raw.params),
      event: raw.event,
      params: clean(raw.params),
      target: raw.target,
      at: raw.at
    })
  end

  defp step(%{kind: :http} = raw, state) do
    add(state, %{kind: :http, method: raw.method, url: raw.url, at: raw.at})
  end

  defp step(_other_view, state), do: state

  defp add(state, step), do: %{state | steps: [step | state.steps]}

  # LiveView's browser side tells them apart when it sends them, in ways that
  # show in the params: a form's change says what changed, a click has a
  # value, and a submit is just the form's fields.
  defp event_kind(%{"_target" => _target}), do: :change
  defp event_kind(params) when map_size(params) == 0, do: :click
  defp event_kind(%{"value" => _value}), do: :click
  defp event_kind(_params), do: :submit

  defp clean(params) do
    params
    |> Enum.reject(fn {key, value} -> dropped?(key) or (key == "value" and value == "") end)
    |> Map.new(fn
      {key, value} when is_map(value) -> {key, clean(value)}
      {key, _value} when is_binary(key) and key != "" -> {key, redact(key, params[key])}
    end)
  end

  defp dropped?(key), do: key in @dropped or String.starts_with?(key, "_unused_")

  defp redact(key, value) do
    if Regex.match?(@sensitive, key), do: @placeholder, else: value
  end

  defp metric(steps) do
    if Enum.any?(steps, &(&1.kind == :open)), do: "live.join", else: "http.request"
  end

  defp body(steps) do
    steps
    |> Enum.chunk_every(2, 1, [nil])
    |> Enum.flat_map_reduce(%{open?: false, previous: nil}, fn [step, next], state ->
      {lines(step, next, state), %{state | open?: open?(step, state), previous: step}}
    end)
    |> then(fn {lines, state} -> lines ++ if(state.open?, do: [close()], else: []) end)
    |> Enum.join("\n")
  end

  defp open?(%{kind: :open}, _state), do: true
  defp open?(_step, state), do: state.open?

  defp close, do: ":ok = Stampede.LiveView.close(view)"

  defp lines(step, next, state) do
    pause(step, state.previous) ++ code(step, next, state)
  end

  defp pause(_step, nil), do: []

  defp pause(step, previous) do
    case step.at - previous.at do
      gap when gap < @min_pause -> []
      gap -> ["Process.sleep(#{inspect(gap |> min(@max_pause) |> round_to(100))})"]
    end
  end

  defp round_to(value, step), do: div(value + div(step, 2), step) * step

  defp code(%{kind: :open} = step, _next, state) do
    close = if state.open?, do: [close()], else: []
    close ++ ["{:ok, view} = Stampede.LiveView.connect(#{inspect(step.url)})"]
  end

  defp code(%{kind: :navigate} = step, _next, _state) do
    ["{:ok, view} = Stampede.LiveView.navigate(view, #{inspect(path(step.url))})"]
  end

  defp code(%{kind: :patch} = step, _next, _state) do
    ["{:ok, view} = Stampede.LiveView.patch(view, #{inspect(path(step.url))})"]
  end

  defp code(%{kind: :http, method: "GET"} = step, _next, _state) do
    ["{:ok, _response} = Stampede.HTTP.get(#{inspect(step.url)})"]
  end

  defp code(%{kind: :http} = step, _next, _state) do
    ["# #{step.method} #{step.url} happened here. Add it by hand, if the rest needs it."]
  end

  defp code(step, next, state) do
    if state.open? do
      arguments = Enum.join(event_arguments(step), ", ")
      call = "Stampede.LiveView.#{step.kind}(view, #{arguments})"
      [result(step, next) <> " = " <> call]
    else
      []
    end
  end

  defp event_arguments(step) do
    params =
      if step.kind == :click and step.params == %{} and step.target == nil,
        do: [],
        else: [inspect(step.params, limit: :infinity, printable_limit: :infinity)]

    target = if step.target, do: ["target: #{step.target}"], else: []
    [inspect(step.event)] ++ params ++ target
  end

  # An event that sends the person to another page doesn't get a reply. Its
  # result says where to go, and the next step goes there.
  defp result(step, %{kind: kind, at: at}) when kind in [:navigate, :patch, :open, :http] do
    if at - step.at <= @caused_by, do: "_result", else: "{:ok, _reply}"
  end

  defp result(_step, _next), do: "{:ok, _reply}"

  defp path(url) do
    uri = URI.parse(url)
    if uri.query, do: "#{uri.path}?#{uri.query}", else: uri.path || "/"
  end
end
