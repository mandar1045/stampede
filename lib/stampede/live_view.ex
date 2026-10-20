defmodule Stampede.LiveView do
  @moduledoc """
  A LiveView client for load tests.

      {:ok, view} = Stampede.LiveView.connect("http://localhost:4000/counter")
      {:ok, _reply} = Stampede.LiveView.click(view, "inc")
      {:ok, _reply} = Stampede.LiveView.submit(view, "save", %{"user" => %{"name" => "jo"}})

  `connect/2` does what a browser does. It fetches the page over HTTP, reads
  the CSRF token and the LiveView's signed session from it, opens the
  LiveView socket with the cookies the page set, and joins the LiveView.

  The connection is a `Stampede.Channels` socket, available as `view.socket`,
  so it sends heartbeats and is closed at the end of an iteration like any
  other.

  ## Metrics

  Inside a run, a view records:

    * `"live.page"` and `"live.page.errors"` - fetching the page
    * `"live.join"` and `"live.join.errors"` - joining the LiveView
    * `"live.event"` and `"live.event.errors"` - events and their replies

  along with the connection metrics listed in `Stampede.Channels`.
  """

  alias Stampede.{Channels, HTTP, Metrics}

  @enforce_keys [:socket, :topic, :url]
  defstruct [:socket, :topic, :url]

  @type t :: %__MODULE__{socket: Channels.socket(), topic: String.t(), url: String.t()}

  @doc """
  Fetches the page at `url` and connects to the LiveView it renders.

  ## Options

    * `:headers` - extra headers for both the page and the socket, such as a
      `cookie` for pages behind a login
    * `:socket_path` - where the LiveView socket is mounted. Defaults to
      `"/live"`.
    * `:timeout` - how long to wait for the page and for the join, in
      milliseconds. Defaults to `5_000`.
    * `:transport_opts` - options for `:gen_tcp` or `:ssl`

  Returns `{:error, {:http_status, status}}` when the page does not load,
  `{:error, :no_live_view}` when it has no LiveView, and `{:error, reply}`
  when the LiveView refuses the join, for example to redirect.
  """
  @spec connect(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def connect(url, opts \\ []) when is_binary(url) do
    opts =
      Keyword.validate!(opts,
        headers: [],
        socket_path: "/live",
        timeout: 5_000,
        transport_opts: []
      )

    uri = URI.parse(url)

    if uri.scheme not in ["http", "https"] or is_nil(uri.host) do
      raise ArgumentError, "expected an http:// or https:// URL, got: #{inspect(url)}"
    end

    with {:ok, page} <- fetch_page(url, opts),
         {:ok, root} <- root_view(page.body),
         params = connect_params(page.body),
         {:ok, socket} <-
           Channels.connect(socket_url(uri, opts[:socket_path]),
             params: params,
             headers: socket_headers(opts[:headers], page.headers),
             transport_opts: opts[:transport_opts]
           ) do
      join(socket, url, root, params, opts)
    end
  end

  @doc """
  Sends a click, like an element with `phx-click={event}` would.

  `value` is what `handle_event/3` gets as its params. Returns `{:ok, reply}`
  once the LiveView has handled it, where `reply` is the map given to
  `{:reply, map, socket}`, or `nil` when `handle_event/3` returned
  `{:noreply, socket}`. Returns `{:error, :channel_crashed}` if the LiveView
  crashes while handling it.

  Takes a `:timeout` option, in milliseconds, that defaults to `5_000`.
  """
  @spec click(t(), String.t(), map(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def click(%__MODULE__{} = view, event, value \\ %{}, opts \\ []) when is_map(value) do
    push(view, "click", event, value, opts)
  end

  @doc """
  Sends a form change, like a form with `phx-change={event}` would.

  `params` are the form's fields, nested the way `handle_event/3` should
  get them, such as `%{"user" => %{"name" => "jo"}}`. Returns the same as
  `click/4`.
  """
  @spec change(t(), String.t(), map(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def change(%__MODULE__{} = view, event, params, opts \\ []) when is_map(params) do
    push(view, "form", event, encode_form(params), opts)
  end

  @doc """
  Submits a form, like a form with `phx-submit={event}` would.

  Takes the same arguments and returns the same as `change/4`.
  """
  @spec submit(t(), String.t(), map(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def submit(%__MODULE__{} = view, event, params, opts \\ []) when is_map(params) do
    push(view, "form", event, encode_form(params), opts)
  end

  @doc """
  Waits for the LiveView to send an update of its own, such as one caused by
  `handle_info/2`, and returns its diff.
  """
  @spec await(t(), timeout()) :: {:ok, map()} | {:error, term()}
  def await(%__MODULE__{} = view, timeout \\ 5_000) do
    Channels.await(view.socket, view.topic, "diff", timeout)
  end

  @doc """
  Closes the connection.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = view), do: Channels.close(view.socket)

  defp fetch_page(url, opts) do
    started_at = System.monotonic_time()
    metrics = Metrics.current()

    case HTTP.get(url, opts[:headers], opts) do
      {:ok, %{status: 200} = page} ->
        Metrics.record_since(metrics, "live.page", started_at)
        {:ok, page}

      {:ok, %{status: status}} ->
        Metrics.increment(metrics, "live.page.errors")
        {:error, {:http_status, status}}

      {:error, reason} ->
        Metrics.increment(metrics, "live.page.errors")
        {:error, reason}
    end
  end

  defp join(socket, url, root, params, opts) do
    topic = "lv:" <> root.id

    payload = %{
      "url" => url,
      "params" => Map.merge(params, %{"_mounts" => 0, "_mount_attempts" => 0}),
      "session" => root.session,
      "static" => root.static,
      "sticky" => false
    }

    case Channels.join(socket, topic, payload, timeout: opts[:timeout], metric: "live.join") do
      {:ok, _rendered} ->
        {:ok, %__MODULE__{socket: socket, topic: topic, url: url}}

      {:error, reason} ->
        Channels.close(socket)
        {:error, reason}
    end
  end

  defp push(view, type, event, value, opts) when is_binary(event) do
    opts = Keyword.validate!(opts, timeout: 5_000)
    payload = %{"type" => type, "event" => event, "value" => value}

    case Channels.push(view.socket, view.topic, "event", payload,
           timeout: opts[:timeout],
           metric: "live.event"
         ) do
      {:ok, %{"diff" => %{"r" => reply}}} -> {:ok, reply}
      {:ok, _response} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp root_view(html) do
    with [tag] <- Regex.run(~r/<[a-z]+\s[^>]*\bdata-phx-main\b[^>]*>/, html),
         id when is_binary(id) <- attribute(tag, "id"),
         session when is_binary(session) <- attribute(tag, "data-phx-session") do
      {:ok, %{id: id, session: session, static: attribute(tag, "data-phx-static")}}
    else
      _other -> {:error, :no_live_view}
    end
  end

  defp connect_params(html) do
    with [tag] <- Regex.run(~r/<meta\s[^>]*name="csrf-token"[^>]*>/, html),
         token when is_binary(token) <- attribute(tag, "content") do
      %{"_csrf_token" => token}
    else
      _other -> %{}
    end
  end

  defp attribute(tag, name) do
    case Regex.run(~r/\s#{name}="([^"]*)"/, tag, capture: :all_but_first) do
      [value] -> value
      nil -> nil
    end
  end

  defp socket_url(%URI{} = uri, path) do
    scheme = if uri.scheme == "https", do: "wss", else: "ws"
    URI.to_string(%URI{uri | scheme: scheme, path: path, query: nil, fragment: nil})
  end

  defp socket_headers(headers, page_headers) do
    page_cookies =
      for {"set-cookie", value} <- page_headers do
        value |> String.split(";", parts: 2) |> hd()
      end

    {cookies, headers} =
      Enum.split_with(headers, fn {name, _value} -> String.downcase(name) == "cookie" end)

    case Enum.map(cookies, &elem(&1, 1)) ++ page_cookies do
      [] -> headers
      cookies -> [{"cookie", Enum.join(cookies, "; ")} | headers]
    end
  end

  defp encode_form(params) do
    params |> flatten(nil) |> URI.encode_query()
  end

  defp flatten(map, prefix) when is_map(map) do
    Enum.flat_map(map, fn {key, value} -> flatten(value, nest(prefix, key)) end)
  end

  defp flatten(list, prefix) when is_list(list) do
    Enum.flat_map(list, &flatten(&1, prefix <> "[]"))
  end

  defp flatten(value, prefix), do: [{prefix, to_string(value)}]

  defp nest(nil, key), do: to_string(key)
  defp nest(prefix, key), do: "#{prefix}[#{key}]"
end
