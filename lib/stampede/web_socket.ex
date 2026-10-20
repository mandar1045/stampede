defmodule Stampede.WebSocket do
  @moduledoc """
  A WebSocket client for load tests, for servers that do not use Phoenix
  Channels.

      {:ok, ws} = Stampede.WebSocket.connect("ws://localhost:4000/ws")
      :ok = Stampede.WebSocket.send(ws, JSON.encode!(%{subscribe: "prices"}))
      {:ok, {:text, text}} = Stampede.WebSocket.await(ws)

  Each connection is a process linked to the caller. It answers the server's
  pings and keeps the last 1,000 frames sent by the server until they are
  read with `await/2`, even after the server closed the connection.

  To time a message and its answer, wrap them in `Stampede.measure/2`:

      Stampede.measure("ws.echo", fn ->
        :ok = Stampede.WebSocket.send(ws, "ping")
        {:ok, _frame} = Stampede.WebSocket.await(ws, match: &(&1 == {:text, "pong"}))
      end)

  ## Metrics

  Inside a run, connections record:

    * `"ws.connect"` and `"ws.connect.errors"`
    * `"ws.disconnects"` - connections closed by the server or the network
    * `"ws.messages"` - text and binary frames received
    * `"ws.messages.sent"` - text and binary frames sent
    * `"ws.messages.dropped"` - frames dropped because the connection
      already held 1,000 unread ones
  """

  import Kernel, except: [send: 2]

  alias Stampede.Metrics
  alias Stampede.WebSocket.Client

  @type t :: pid()
  @type frame :: {:text, String.t()} | {:binary, binary()}

  @sockets_key {__MODULE__, :sockets}

  @doc """
  Connects to the WebSocket at `url`, a `ws://` or `wss://` URL.

  ## Options

    * `:headers` - extra headers for the upgrade request, such as
      `{"sec-websocket-protocol", "graphql-transport-ws"}`
    * `:connect_timeout` - how long to wait for the connection, in
      milliseconds. Defaults to `10_000`.
    * `:transport_opts` - options for `:gen_tcp` or `:ssl`, given to
      `Mint.HTTP.connect/4`

  Returns `{:error, reason}` when the connection fails, such as a
  `Mint.TransportError` when nothing is listening, or a
  `Mint.WebSocket.UpgradeFailureError` when the server refuses the upgrade.
  """
  @spec connect(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def connect(url, opts \\ []) when is_binary(url) do
    opts = Keyword.validate!(opts, headers: [], connect_timeout: 10_000, transport_opts: [])
    uri = URI.parse(url)

    if uri.scheme not in ["ws", "wss"] or is_nil(uri.host) do
      raise ArgumentError, "expected a ws:// or wss:// URL, got: #{inspect(url)}"
    end

    path = if uri.query, do: "#{uri.path || "/"}?#{uri.query}", else: uri.path || "/"

    with {:ok, ws} <- Client.start_link(uri, path, opts) do
      if Metrics.current(), do: Process.put(@sockets_key, [ws | Process.get(@sockets_key, [])])
      {:ok, ws}
    end
  end

  @doc """
  Sends `frame` to the server: `{:text, text}`, `{:binary, data}`, or a
  string, sent as text.

  Returns `{:error, {:closed, reason}}` when the connection is closed.
  """
  @spec send(t(), frame() | String.t()) :: :ok | {:error, term()}
  def send(ws, text) when is_binary(text), do: send(ws, {:text, text})

  def send(ws, {type, data} = frame) when type in [:text, :binary] and is_binary(data) do
    Client.request(ws, {:send, frame})
  end

  @doc """
  Waits until the server sends a text or binary frame, and returns it.

  Frames that arrived before the call are looked at first, oldest first.
  Returns `{:error, :timeout}` if none arrives in time, or
  `{:error, {:closed, reason}}` when the connection closed and no frame is
  left to read.

  The last argument is a timeout in milliseconds, or a list of options:

    * `:timeout` - how long to wait, in milliseconds. Defaults to `5_000`.
    * `:match` - a function that gets each frame and returns whether it is
      the one to wait for. Frames that do not match are kept for later:

          Stampede.WebSocket.await(ws, match: &match?({:text, "ack:" <> _}, &1))
  """
  @spec await(t(), timeout() | keyword()) :: {:ok, frame()} | {:error, term()}
  def await(ws, timeout_or_opts \\ [])

  def await(ws, timeout) when is_integer(timeout) or timeout == :infinity do
    await(ws, timeout: timeout)
  end

  def await(ws, opts) when is_list(opts) do
    opts = Keyword.validate!(opts, timeout: 5_000, match: nil)
    Client.request(ws, {:await, opts[:match], opts[:timeout]})
  end

  @doc """
  Closes the connection and waits for its process to stop.
  """
  @spec close(t()) :: :ok
  def close(ws) do
    ref = Process.monitor(ws)
    Client.request(ws, :close)

    receive do
      {:DOWN, ^ref, :process, ^ws, _reason} -> :ok
    end
  end

  @doc false
  def close_all do
    for ws <- Process.delete(@sockets_key) || [], do: close(ws)
    :ok
  end
end
