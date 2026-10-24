defmodule Stampede.Channels do
  @moduledoc """
  A Phoenix Channels client for load tests.

      {:ok, socket} = Stampede.Channels.connect("ws://localhost:4000/socket", params: %{token: token})
      {:ok, _reply} = Stampede.Channels.join(socket, "room:lobby")
      {:ok, _reply} = Stampede.Channels.push(socket, "room:lobby", "new_msg", %{body: "hi"})
      {:ok, payload} = Stampede.Channels.await(socket, "room:lobby", "new_msg")

  Each socket is a process linked to the caller. It sends heartbeats, matches
  every reply to the request it answers, and keeps the last 1,000 messages
  pushed or broadcast by the server until they are read with `await/4`.

  ## Metrics

  Inside a run, sockets record:

    * `"ws.connect"` and `"ws.connect.errors"`
    * `"ws.disconnects"` - connections closed by the server or the network
    * `"channel.join"` and `"channel.join.errors"`
    * `"channel.push"` and `"channel.push.errors"`
    * `"channel.leave"` and `"channel.leave.errors"`
    * `"channel.messages"` - messages pushed or broadcast by the server
    * `"channel.messages.dropped"` - messages dropped because the socket
      already held 1,000 unread ones

  Error replies, timeouts and closed connections all count as errors.

  ## Binary payloads

  With the default `"2.0.0"` serializer, a payload can be `{:binary, data}`
  instead of a map, and pushes, replies and broadcasts with binary payloads
  from the server come back the same way, as with Phoenix itself:

      {:ok, {:binary, chunk}} = Stampede.Channels.push(socket, "file:1", "read", {:binary, <<0, 64>>})

  Servers that add message types of their own, such as custom binary frames,
  can be given their own `Stampede.Channels.Serializer`.
  """

  alias Stampede.Channels.{Serializer, Socket}
  alias Stampede.Metrics

  @type socket :: pid()
  @type payload :: map() | {:binary, binary()}

  @sockets_key {__MODULE__, :sockets}
  @versions ["1.0.0", "2.0.0"]

  @doc """
  Connects to the Phoenix socket at `url`.

  `url` is the socket's endpoint as given to the JavaScript client, such as
  `"ws://localhost:4000/socket"`. `/websocket` is added to its path unless it
  is already there.

  ## Options

    * `:params` - query parameters sent with the connection, often used for
      authentication
    * `:headers` - extra headers for the upgrade request
    * `:vsn` - the serializer version, `"2.0.0"` (the default) or `"1.0.0"`.
      A `vsn` query parameter in `url` takes precedence.
    * `:serializer` - a module that implements `Stampede.Channels.Serializer`,
      to use instead of the built-in one for `:vsn`, for servers that extend
      the protocol
    * `:connect_timeout` - how long to wait for the connection, in
      milliseconds. Defaults to `10_000`.
    * `:heartbeat_interval` - how often to send a heartbeat, in milliseconds,
      or `nil` to never send one. Defaults to `30_000`, like the JavaScript
      client. The connection is closed when a heartbeat is still unanswered
      by the time the next one is due.
    * `:transport_opts` - options for `:gen_tcp` or `:ssl`, given to
      `Mint.HTTP.connect/4`

  Returns `{:error, reason}` when the connection fails, such as a
  `Mint.TransportError` when nothing is listening, or a
  `Mint.WebSocket.UpgradeFailureError` when the socket's `connect/3`
  refuses it.
  """
  @spec connect(String.t(), keyword()) :: {:ok, socket()} | {:error, term()}
  def connect(url, opts \\ []) when is_binary(url) do
    opts =
      Keyword.validate!(opts,
        params: %{},
        headers: [],
        vsn: "2.0.0",
        serializer: nil,
        connect_timeout: 10_000,
        heartbeat_interval: 30_000,
        transport_opts: []
      )

    {uri, path, vsn} = request(url, opts)
    serializer = opts[:serializer] || if(vsn == "1.0.0", do: Serializer.V1, else: Serializer.V2)

    with {:ok, socket} <- Socket.start_link(uri, path, serializer, opts) do
      track(socket)
      {:ok, socket}
    end
  end

  @doc """
  Joins `topic`, sending `payload` to the channel's `join/3` callback.

  Returns `{:ok, response}` when the channel accepts the join and
  `{:error, response}` when it refuses it. It may also return
  `{:error, :timeout}`, or `{:error, {:closed, reason}}` when the connection
  closes first.

  ## Options

    * `:timeout` - how long to wait for the reply, in milliseconds. Defaults
      to `5_000`.
    * `:metric` - the timing to record the join as, or `nil` to record
      nothing. Defaults to `"channel.join"`.
  """
  @spec join(socket(), String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def join(socket, topic, payload \\ %{}, opts \\ []) when is_binary(topic) do
    opts = Keyword.validate!(opts, timeout: 5_000, metric: "channel.join")
    Socket.request(socket, {:join, topic, payload, opts})
  end

  @doc """
  Pushes `event` with `payload` to `topic` and waits for the reply.

  Returns `{:ok, response}` or `{:error, response}`, depending on what the
  channel's `handle_in/3` replied. Use `cast/4` for events the channel does
  not reply to.

  Takes the same options as `join/4`, with `:metric` defaulting to
  `"channel.push"`.
  """
  @spec push(socket(), String.t(), String.t(), payload(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def push(socket, topic, event, payload \\ %{}, opts \\ [])
      when is_binary(topic) and is_binary(event) do
    opts = Keyword.validate!(opts, timeout: 5_000, metric: "channel.push")
    Socket.request(socket, {:push, topic, event, payload, opts})
  end

  @doc """
  Pushes `event` with `payload` to `topic` without waiting for a reply.
  """
  @spec cast(socket(), String.t(), String.t(), payload()) :: :ok
  def cast(socket, topic, event, payload \\ %{}) when is_binary(topic) and is_binary(event) do
    Socket.request(socket, {:cast, topic, event, payload})
    :ok
  end

  @doc """
  Waits until the server pushes or broadcasts `event` on `topic`, and returns
  its payload.

  Messages that arrived before the call are looked at first, oldest first.
  Returns `{:error, :timeout}` if no such message arrives in time.

  The last argument is a timeout in milliseconds, or a list of options:

    * `:timeout` - how long to wait, in milliseconds. Defaults to `5_000`.
    * `:match` - a function that gets each payload and returns whether it is
      the one to wait for. Useful when other VUs broadcast the same event:

          Stampede.Channels.await(socket, "room:lobby", "shout", match: &(&1["from"] == vu.id))
  """
  @spec await(socket(), String.t(), String.t(), timeout() | keyword()) ::
          {:ok, term()} | {:error, term()}
  def await(socket, topic, event, timeout_or_opts \\ [])

  def await(socket, topic, event, timeout) when is_integer(timeout) or timeout == :infinity do
    await(socket, topic, event, timeout: timeout)
  end

  def await(socket, topic, event, opts)
      when is_binary(topic) and is_binary(event) and is_list(opts) do
    opts = Keyword.validate!(opts, timeout: 5_000, match: nil)
    Socket.request(socket, {:await, topic, event, opts[:match], opts[:timeout]})
  end

  @doc """
  Leaves `topic`.

  Takes the same options as `join/4`, with `:metric` defaulting to
  `"channel.leave"`.
  """
  @spec leave(socket(), String.t(), keyword()) :: :ok | {:error, term()}
  def leave(socket, topic, opts \\ []) when is_binary(topic) do
    opts = Keyword.validate!(opts, timeout: 5_000, metric: "channel.leave")

    with {:ok, _response} <- Socket.request(socket, {:leave, topic, opts}) do
      :ok
    end
  end

  @doc """
  Closes the connection and waits for the socket to stop.
  """
  @spec close(socket()) :: :ok
  def close(socket) do
    ref = Process.monitor(socket)
    Socket.request(socket, :close)

    receive do
      {:DOWN, ^ref, :process, ^socket, _reason} -> :ok
    end
  end

  @doc false
  def close_all do
    for socket <- Process.delete(@sockets_key) || [], do: close(socket)
    :ok
  end

  defp track(socket) do
    if Metrics.current() do
      Process.put(@sockets_key, [socket | Process.get(@sockets_key, [])])
    end
  end

  defp request(url, opts) do
    uri = URI.parse(url)

    if uri.scheme not in ["ws", "wss"] or is_nil(uri.host) do
      raise ArgumentError, "expected a ws:// or wss:// URL, got: #{inspect(url)}"
    end

    path = String.trim_trailing(uri.path || "", "/")
    path = if String.ends_with?(path, "/websocket"), do: path, else: path <> "/websocket"
    params = Map.new(opts[:params], fn {key, value} -> {to_string(key), to_string(value)} end)

    query =
      URI.decode_query(uri.query || "")
      |> Map.merge(params)
      |> Map.put_new("vsn", opts[:vsn])

    if query["vsn"] not in @versions do
      raise ArgumentError,
            "expected :vsn to be one of #{inspect(@versions)}, got: #{inspect(query["vsn"])}"
    end

    {uri, path <> "?" <> URI.encode_query(query), query["vsn"]}
  end
end
