defmodule Stampede.LiveView do
  @moduledoc """
  A LiveView client for load tests.

      {:ok, view} = Stampede.LiveView.connect("http://localhost:4000/counter")
      {:ok, _reply} = Stampede.LiveView.click(view, "inc")
      {:ok, _reply} = Stampede.LiveView.submit(view, "save", %{"user" => %{"name" => "jo"}})
      {:ok, view} = Stampede.LiveView.navigate(view, "/posts")

  `connect/2` does what a browser does. It fetches the page over HTTP, reads
  the CSRF token and the LiveView's signed session from it, opens the
  LiveView socket with the cookies the page set, and joins the LiveView.

  The connection is a `Stampede.Channels` socket, available as `view.socket`,
  so it sends heartbeats and is closed at the end of an iteration like any
  other. `view.url` is the URL of the LiveView the view is on.

  ## Navigation

  `patch/3` and `navigate/3` move between pages like `<.link patch>` and
  `<.link navigate>` do, without loading the page again when LiveView would
  not. When an event makes the LiveView navigate on its own, it returns
  `{:error, {:live_redirect, %{"to" => to}}}`, or `{:error, {:redirect,
  %{"to" => to}}}` for a full redirect, as `Phoenix.LiveViewTest` does.
  Follow either one with `navigate/3`.

  ## Metrics

  Inside a run, a view records:

    * `"live.page"` and `"live.page.errors"` - fetching the page
    * `"live.join"` and `"live.join.errors"` - joining the LiveView
    * `"live.event"` and `"live.event.errors"` - events and their replies
    * `"live.patch"` and `"live.patch.errors"` - patches
    * `"live.navigate"` and `"live.navigate.errors"` - navigations over the
      same socket. A navigation that needs a new page load records that
      load instead.

  along with the connection metrics listed in `Stampede.Channels`.
  """

  alias Stampede.{Channels, HTTP, Metrics}

  @derive {Inspect, only: [:socket, :topic, :url]}
  @enforce_keys [:socket, :topic, :url]
  defstruct [:socket, :topic, :url, :root, :params, :opts]

  @type t :: %__MODULE__{socket: Channels.socket(), topic: String.t(), url: String.t()}

  @doc """
  Fetches the page at `url` and connects to the LiveView it renders.

  ## Options

    * `:headers` - extra headers for both the page and the socket, such as a
      `cookie` for pages behind a login
    * `:max_redirects` - how many redirects to follow while loading the page,
      keeping the cookies they set. Defaults to `5`.
    * `:socket_path` - where the LiveView socket is mounted. Defaults to
      `"/live"`.
    * `:timeout` - how long to wait for each page request and for the join,
      in milliseconds. Defaults to `5_000`.
    * `:transport_opts` - options for `:gen_tcp` or `:ssl`

  Returns `{:error, {:http_status, status}}` when the page does not load or
  redirects too many times, `{:error, :no_live_view}` when it has no
  LiveView, and `{:error, reply}` when the LiveView refuses the join, for
  example to redirect.
  """
  @spec connect(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def connect(url, opts \\ []) when is_binary(url) do
    opts =
      Keyword.validate!(opts,
        headers: [],
        max_redirects: 5,
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
         opts = Keyword.put(opts, :headers, with_cookies(opts[:headers], page.cookies)),
         {:ok, socket} <-
           Channels.connect(socket_url(page.url, opts[:socket_path]),
             params: params,
             headers: opts[:headers],
             transport_opts: opts[:transport_opts]
           ) do
      join(socket, page.url, root, params, opts)
    end
  end

  @doc """
  Patches the LiveView to `to`, like `<.link patch={to}>` would.

  `to` is a path, such as `"/posts?page=2"`, or a full URL. The LiveView's
  `handle_params/3` runs, and `{:ok, view}` returns the view at its new URL.
  When `to` belongs to another LiveView, it navigates there with
  `navigate/3` instead, as a browser does.

  Takes a `:timeout` option, in milliseconds, that defaults to `5_000`.
  """
  @spec patch(t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def patch(%__MODULE__{} = view, to, opts \\ []) when is_binary(to) do
    opts = Keyword.validate!(opts, timeout: 5_000)
    url = view.url |> URI.merge(to) |> URI.to_string()

    case Channels.push(view.socket, view.topic, "live_patch", %{"url" => url},
           timeout: opts[:timeout],
           metric: "live.patch"
         ) do
      {:ok, %{"link_redirect" => true}} ->
        navigate(view, url, opts)

      result ->
        with {:ok, _reply} <- event_result(result), do: {:ok, %{view | url: url}}
    end
  end

  @doc """
  Navigates to the LiveView at `to`, like `<.link navigate={to}>` would.

  `to` is a path or a full URL. When the new LiveView is in the same
  `live_session`, it joins over the same socket. Otherwise the page is
  loaded again with `connect/2`, as a browser does. Returns `{:ok, view}`
  for the new LiveView.

  Takes a `:timeout` option, in milliseconds, that defaults to `5_000`.
  """
  @spec navigate(t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def navigate(%__MODULE__{} = view, to, opts \\ []) when is_binary(to) do
    opts = Keyword.validate!(opts, timeout: 5_000)
    url = view.url |> URI.merge(to) |> URI.to_string()
    started_at = System.monotonic_time()
    _ = Channels.leave(view.socket, view.topic, timeout: opts[:timeout])

    payload = %{
      "redirect" => url,
      "params" => Map.merge(view.params, %{"_mounts" => 0, "_live_referer" => view.url}),
      "session" => view.root.session,
      "static" => view.root.static,
      "sticky" => false
    }

    # The metric is recorded here, since a refused join is how LiveView asks
    # for a page load and is not an error.
    case Channels.join(view.socket, view.topic, payload, timeout: opts[:timeout], metric: nil) do
      {:ok, _rendered} ->
        Metrics.record_since(Metrics.current(), "live.navigate", started_at)
        {:ok, %{view | url: url}}

      {:error, %{"reason" => "unauthorized"}} ->
        Channels.close(view.socket)
        connect(url, view.opts)

      {:error, reason} ->
        Metrics.increment(Metrics.current(), "live.navigate.errors")
        {:error, redirect_reason(reason)}
    end
  end

  @doc """
  Sends a click, like an element with `phx-click={event}` would.

  `value` is what `handle_event/3` gets as its params. Returns `{:ok, reply}`
  once the LiveView has handled it, where `reply` is the map given to
  `{:reply, map, socket}`, or `nil` when `handle_event/3` returned
  `{:noreply, socket}`. Returns `{:error, :channel_crashed}` if the LiveView
  crashes while handling it.

  ## Options

    * `:target` - the component to send the event to, like `phx-target`
      does. It is the number LiveView renders for `phx-target={@myself}`;
      components are numbered from 1, in the order they first render.
    * `:timeout` - how long to wait for the reply, in milliseconds. Defaults
      to `5_000`.
  """
  @spec click(t(), String.t(), map(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def click(%__MODULE__{} = view, event, value \\ %{}, opts \\ []) when is_map(value) do
    push(view, "click", event, value, opts)
  end

  @doc """
  Sends a form change, like a form with `phx-change={event}` would.

  `params` are the form's fields, nested the way `handle_event/3` should
  get them, such as `%{"user" => %{"name" => "jo"}}`. Takes the same
  options and returns the same as `click/4`.
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

    case load(url, [], opts[:max_redirects], opts) do
      {:ok, page} ->
        Metrics.record_since(metrics, "live.page", started_at)
        {:ok, page}

      {:error, reason} ->
        Metrics.increment(metrics, "live.page.errors")
        {:error, reason}
    end
  end

  defp load(url, cookies, redirects_left, opts) do
    with {:ok, response} <- HTTP.get(url, with_cookies(opts[:headers], cookies), opts) do
      cookies = store_cookies(cookies, response.headers)

      case {response.status, List.keyfind(response.headers, "location", 0)} do
        {200, _location} ->
          {:ok, %{url: url, body: response.body, cookies: cookies}}

        {status, {"location", location}}
        when status in [301, 302, 303, 307, 308] and redirects_left > 0 ->
          url |> URI.merge(location) |> URI.to_string() |> load(cookies, redirects_left - 1, opts)

        {status, _location} ->
          {:error, {:http_status, status}}
      end
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
        {:ok,
         %__MODULE__{
           socket: socket,
           topic: topic,
           url: url,
           root: root,
           params: params,
           opts: opts
         }}

      {:error, reason} ->
        Channels.close(socket)
        follow(url, redirect_reason(reason), opts)
    end
  end

  # A LiveView that redirects while mounting is followed like an HTTP redirect.
  defp follow(url, {kind, %{"to" => to}} = reason, opts)
       when kind in [:live_redirect, :redirect] do
    if opts[:max_redirects] > 0 do
      url
      |> URI.merge(to)
      |> URI.to_string()
      |> connect(Keyword.update!(opts, :max_redirects, &(&1 - 1)))
    else
      {:error, reason}
    end
  end

  defp follow(_url, reason, _opts), do: {:error, reason}

  defp push(view, type, event, value, opts) when is_binary(event) do
    opts = Keyword.validate!(opts, target: nil, timeout: 5_000)
    payload = %{"type" => type, "event" => event, "value" => value}
    payload = if opts[:target], do: Map.put(payload, "cid", opts[:target]), else: payload

    view.socket
    |> Channels.push(view.topic, "event", payload, timeout: opts[:timeout], metric: "live.event")
    |> event_result()
  end

  defp event_result({:ok, %{"diff" => %{"r" => reply}}}), do: {:ok, reply}

  defp event_result({:ok, %{"live_redirect" => _} = response}),
    do: {:error, redirect_reason(response)}

  defp event_result({:ok, %{"redirect" => _} = response}), do: {:error, redirect_reason(response)}
  defp event_result({:ok, _response}), do: {:ok, nil}
  defp event_result({:error, reason}), do: {:error, reason}

  defp redirect_reason(%{"live_redirect" => opts}), do: {:live_redirect, opts}
  defp redirect_reason(%{"redirect" => opts}), do: {:redirect, opts}
  defp redirect_reason(reason), do: reason

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

  defp socket_url(url, path) do
    %URI{} = uri = URI.parse(url)
    scheme = if uri.scheme == "https", do: "wss", else: "ws"
    URI.to_string(%URI{uri | scheme: scheme, path: path, query: nil, fragment: nil})
  end

  # Cookies are kept as {name, "name=value"}, so a later Set-Cookie with the
  # same name replaces the earlier one.
  defp store_cookies(cookies, headers) do
    for {"set-cookie", value} <- headers, reduce: cookies do
      cookies ->
        [pair | _attributes] = String.split(value, ";", parts: 2)
        [name | _value] = String.split(pair, "=", parts: 2)
        List.keystore(cookies, name, 0, {name, pair})
    end
  end

  defp with_cookies(headers, []), do: headers

  defp with_cookies(headers, cookies) do
    {given, headers} =
      Enum.split_with(headers, fn {name, _value} -> String.downcase(name) == "cookie" end)

    values = Enum.map(given, &elem(&1, 1)) ++ Enum.map(cookies, &elem(&1, 1))
    [{"cookie", Enum.join(values, "; ")} | headers]
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
