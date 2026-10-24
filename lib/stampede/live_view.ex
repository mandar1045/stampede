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

  ## Uploads

  `upload/4` sends files to an upload, the way a browser does once they are
  chosen in a `live_file_input/1`, so that a form can be submitted with them:

      :ok = Stampede.LiveView.upload(view, "avatar", [%{name: "me.jpg", content: photo}])
      {:ok, _reply} = Stampede.LiveView.submit(view, "save", %{"user" => %{"name" => "jo"}})

  ## Metrics

  Inside a run, a view records:

    * `"live.page"` and `"live.page.errors"` - fetching the page
    * `"live.join"` and `"live.join.errors"` - joining the LiveView
    * `"live.event"` and `"live.event.errors"` - events and their replies
    * `"live.patch"` and `"live.patch.errors"` - patches
    * `"live.navigate"` and `"live.navigate.errors"` - navigations over the
      same socket. A navigation that needs a new page load records that
      load instead.
    * `"live.upload"` and `"live.upload.errors"` - uploads, from asking the
      LiveView to allow them to the last chunk

  along with the connection metrics listed in `Stampede.Channels`.
  """

  alias Stampede.{Channels, HTTP, Metrics}

  @derive {Inspect, only: [:socket, :topic, :url]}
  @enforce_keys [:socket, :topic, :url]
  defstruct [:socket, :topic, :url, :root, :params, :opts]

  @type t :: %__MODULE__{socket: Channels.socket(), topic: String.t(), url: String.t()}

  @uploads_key {__MODULE__, :uploads}

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
        with {:ok, _reply} <- result |> diff_uploads(view) |> event_result(),
             do: {:ok, %{view | url: url}}
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
      {:ok, reply} ->
        Metrics.record_since(Metrics.current(), "live.navigate", started_at)
        remember_uploads(view.socket, view.topic, reply["rendered"], :replace)
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

  @typedoc """
  A file for `upload/4`: its `:name`, its `:content` and optionally its MIME
  `:type`.
  """
  @type file :: %{
          required(:name) => String.t(),
          required(:content) => binary(),
          optional(:type) => String.t()
        }

  @doc """
  Uploads `files` to the LiveView's upload `name`, as a browser does once
  they are chosen in its `live_file_input/1`.

  Each file is a map with its `:name` and `:content`, and optionally its
  MIME `:type`, otherwise guessed from the name's extension for common
  files:

      photo = :crypto.strong_rand_bytes(200_000)
      :ok = Stampede.LiveView.upload(view, "avatar", [%{name: "me.jpg", content: photo}])
      {:ok, _reply} = Stampede.LiveView.submit(view, "save", %{"user" => %{"name" => "jo"}})

  It asks the LiveView to allow the files, sends each one in chunks over the
  view's socket and reports its progress, so that once it returns `:ok`,
  `consume_uploaded_entries/3` can read them. The `phx-change` event a
  browser sends when files are chosen is not sent; use `change/4` if the
  LiveView needs it.

  The upload's input must have been rendered when the view joined, or in
  the reply to one of its events. An upload of a component is sent to that
  component.

  Returns `{:error, {:no_upload, name}}` when no such upload was rendered,
  and `{:error, {:rejected, errors}}` when the LiveView refuses the files,
  with a `{name, reason}` tuple per error. `name` is the file's, or the
  upload's for errors about the whole upload, such as
  `{"avatar", "too_many_files"}`.

  ## Options

    * `:target` - the component the upload belongs to, when it is not the
      one that renders its input
    * `:timeout` - how long to wait for each reply, in milliseconds.
      Defaults to `5_000`.
  """
  @spec upload(t(), String.t(), [file()], keyword()) :: :ok | {:error, term()}
  def upload(%__MODULE__{} = view, name, files, opts \\ [])
      when is_binary(name) and is_list(files) do
    opts = Keyword.validate!(opts, target: nil, timeout: 5_000)
    entries = Enum.map(files, &entry!/1)
    started_at = System.monotonic_time()
    uploads = Process.get(@uploads_key, %{}) |> Map.get({view.socket, view.topic}, %{})

    result =
      case Map.fetch(uploads, name) do
        {:ok, {ref, cid}} -> send_files(view, name, ref, opts[:target] || cid, entries, opts)
        :error -> {:error, {:no_upload, name}}
      end

    case result do
      :ok -> Metrics.record_since(Metrics.current(), "live.upload", started_at)
      {:error, _reason} -> Metrics.increment(Metrics.current(), "live.upload.errors")
    end

    result
  end

  @doc """
  Waits for the LiveView to send an update of its own, such as one caused by
  `handle_info/2`, and returns its diff.

  Takes a timeout in milliseconds, or the same options as
  `Stampede.Channels.await/4`, with `:match` getting each diff.
  """
  @spec await(t(), timeout() | keyword()) :: {:ok, map()} | {:error, term()}
  def await(%__MODULE__{} = view, timeout_or_opts \\ []) do
    Channels.await(view.socket, view.topic, "diff", timeout_or_opts)
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
    request_opts = [
      headers: with_cookies(opts[:headers], cookies),
      timeout: opts[:timeout],
      transport_opts: opts[:transport_opts],
      metric: nil
    ]

    with {:ok, response} <- HTTP.request(:get, url, request_opts) do
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
      {:ok, reply} ->
        remember_uploads(socket, topic, reply["rendered"], :replace)

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
    |> diff_uploads(view)
    |> event_result()
  end

  @types %{
    ".csv" => "text/csv",
    ".gif" => "image/gif",
    ".jpeg" => "image/jpeg",
    ".jpg" => "image/jpeg",
    ".json" => "application/json",
    ".mp3" => "audio/mpeg",
    ".mp4" => "video/mp4",
    ".pdf" => "application/pdf",
    ".png" => "image/png",
    ".svg" => "image/svg+xml",
    ".txt" => "text/plain",
    ".webp" => "image/webp",
    ".zip" => "application/zip"
  }

  # Entry refs only need to be unique within a page, like the counter the
  # JavaScript client uses.
  defp entry!(%{name: name, content: content} = file)
       when is_binary(name) and is_binary(content) do
    %{
      ref: Integer.to_string(System.unique_integer([:positive])),
      name: name,
      type: file[:type] || Map.get(@types, String.downcase(Path.extname(name)), ""),
      content: content
    }
  end

  defp entry!(other) do
    raise ArgumentError,
          "expected a file to be a map with a :name and a :content, got: #{inspect(other)}"
  end

  defp send_files(view, name, ref, cid, entries, opts) do
    preflight = %{
      "ref" => ref,
      "entries" =>
        for entry <- entries do
          %{
            "ref" => entry.ref,
            "name" => entry.name,
            "relative_path" => "",
            "size" => byte_size(entry.content),
            "type" => entry.type,
            "last_modified" => System.system_time(:millisecond)
          }
        end
    }

    with {:ok, reply} <- allow(view, preflight, cid, opts),
         {:ok, tokens, config} <- allowed(reply, name, ref, entries) do
      Enum.reduce_while(entries, :ok, fn entry, :ok ->
        case send_file(view, ref, cid, entry, tokens[entry.ref], config, opts) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  # With max_entries: 1, a new file cancels the previous one, but LiveView
  # only drops it once its upload channel exits. Browsers send phx-change
  # first, which gives it that time. Here, a second preflight does.
  defp allow(view, payload, cid, opts) do
    with {:ok, %{"entries" => tokens, "errors" => errors}}
         when map_size(tokens) == 0 and map_size(errors) == 0 <-
           upload_push(view, "allow_upload", payload, cid, opts) do
      upload_push(view, "allow_upload", payload, cid, opts)
    end
  end

  defp allowed(%{"entries" => tokens, "errors" => errors} = reply, _name, _ref, entries)
       when map_size(tokens) == length(entries) and map_size(errors) == 0 do
    {:ok, tokens, reply["config"]}
  end

  # Errors of files from earlier calls stay on the upload until LiveView
  # drops them, so only the ones about these files are returned.
  defp allowed(reply, name, ref, entries) do
    names = entries |> Map.new(&{&1.ref, &1.name}) |> Map.put(ref, name)

    errors =
      case reply do
        %{"error" => errors} ->
          Enum.map(errors, fn [ref, reason] -> {ref, reason} end)

        %{"errors" => errors} ->
          for {ref, reasons} <- errors, reason <- reasons, do: {ref, reason}

        _other ->
          []
      end

    case for({ref, reason} <- errors, Map.has_key?(names, ref), do: {names[ref], reason}) do
      [] ->
        tokens = Map.get(reply, "entries", %{})
        not_allowed = for entry <- entries, not is_map_key(tokens, entry.ref), do: entry.name
        {:error, {:rejected, Enum.map(not_allowed, &{&1, "not_allowed"})}}

      errors ->
        {:error, {:rejected, errors}}
    end
  end

  # Each file is joined to a channel of its own with the token the LiveView
  # gave it, and sent in chunks. Its progress goes to the LiveView after
  # every chunk, and an upload is done once it reaches 100.
  defp send_file(view, ref, cid, entry, token, config, opts) do
    topic = "lvu:" <> entry.ref
    channel_opts = [timeout: opts[:timeout], metric: nil]

    with {:ok, _reply} <- Channels.join(view.socket, topic, %{"token" => token}, channel_opts) do
      upload = %{
        view: view,
        topic: topic,
        ref: ref,
        cid: cid,
        entry: entry,
        chunk_size: config["chunk_size"],
        chunk_opts: [timeout: config["chunk_timeout"] || opts[:timeout], metric: nil],
        opts: opts
      }

      send_chunks(upload, entry.content, 0, -1)
    end
  end

  # An empty file is sent as one empty chunk, which completes it too.
  defp send_chunks(upload, content, sent, reported) do
    size = min(byte_size(content), upload.chunk_size)
    chunk = binary_part(content, 0, size)
    rest = binary_part(content, size, byte_size(content) - size)
    sent = sent + size
    total = byte_size(upload.entry.content)
    progress = if sent == total, do: 100, else: div(sent * 100, total)

    with {:ok, _reply} <-
           Channels.push(
             upload.view.socket,
             upload.topic,
             "chunk",
             {:binary, chunk},
             upload.chunk_opts
           ),
         {:ok, _reply} <- report_progress(upload, progress, reported) do
      if rest == <<>>, do: :ok, else: send_chunks(upload, rest, sent, max(progress, reported))
    end
  end

  # Like the JavaScript client, progress is only reported when it grows.
  defp report_progress(_upload, progress, reported) when progress <= reported, do: {:ok, nil}

  defp report_progress(upload, progress, _reported) do
    payload = %{
      "event" => nil,
      "ref" => upload.ref,
      "entry_ref" => upload.entry.ref,
      "progress" => progress
    }

    upload_push(upload.view, "progress", payload, upload.cid, upload.opts)
  end

  defp upload_push(view, event, payload, cid, opts) do
    payload = if cid, do: Map.put(payload, "cid", cid), else: payload

    view.socket
    |> Channels.push(view.topic, event, payload, timeout: opts[:timeout], metric: nil)
    |> diff_uploads(view)
  end

  # LiveView renders upload inputs with refs of its own, which the client
  # reads from what it renders: when the LiveView joins, and in the diffs
  # that replies carry. Each VU keeps them by socket and topic.
  defp diff_uploads({:ok, %{"diff" => diff}} = result, view) do
    remember_uploads(view.socket, view.topic, diff, :merge)
    result
  end

  defp diff_uploads(result, _view), do: result

  defp remember_uploads(socket, topic, rendered, mode) when is_map(rendered) do
    found = find_uploads(rendered)

    if mode == :replace or found != %{} do
      all = Process.get(@uploads_key, %{})

      all =
        if mode == :replace,
          do: Map.filter(all, fn {{socket, _topic}, _uploads} -> Process.alive?(socket) end),
          else: all

      Process.put(@uploads_key, Map.update(all, {socket, topic}, found, &Map.merge(&1, found)))
    end

    :ok
  end

  defp remember_uploads(_socket, _topic, _rendered, _mode), do: :ok

  # `live_file_input/1` renders each attribute of its input as a dynamic of
  # one node, so the node with an upload ref also has the input's name.
  # Uploads of components are found under "c", by the component's ID.
  defp find_uploads(rendered) do
    {components, view} = Map.pop(rendered, "c", %{})

    for {cid, component} <- components, reduce: find_uploads(view, nil, %{}) do
      found -> find_uploads(component, String.to_integer(cid), found)
    end
  end

  defp find_uploads(node, cid, found) when is_map(node) or is_list(node) do
    values = if is_map(node), do: Map.values(node), else: node

    found =
      with [ref] <-
             for(" data-phx-upload-ref=" <> _ = value <- values, do: attribute_value(value)),
           [name] <- for(" name=" <> _ = value <- values, do: attribute_value(value)) do
        Map.put_new(found, name, {ref, cid})
      else
        _other -> found
      end

    Enum.reduce(values, found, &find_uploads(&1, cid, &2))
  end

  defp find_uploads(_value, _cid, found), do: found

  defp attribute_value(attribute) do
    [_name, value] = String.split(attribute, "=", parts: 2)
    value |> String.trim("\"") |> unescape_html()
  end

  defp unescape_html(value) do
    value
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
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
