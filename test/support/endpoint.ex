defmodule Stampede.TestEndpoint do
  use Phoenix.Endpoint, otp_app: :stampede

  @session_options [store: :cookie, key: "_stampede_key", signing_salt: "stampede"]

  socket "/socket", Stampede.TestSocket, websocket: true, longpoll: false

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false

  plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: JSON
  plug Plug.Session, @session_options
  plug Stampede.TestRouter

  def socket_url do
    {:ok, {_ip, port}} = server_info(:http)
    "ws://127.0.0.1:#{port}/socket"
  end

  def echo_url do
    {:ok, {_ip, port}} = server_info(:http)
    "ws://127.0.0.1:#{port}/api/echo-socket"
  end

  def page_url(path) do
    {:ok, {_ip, port}} = server_info(:http)
    "http://127.0.0.1:#{port}#{path}"
  end
end

defmodule Stampede.TestSocket do
  use Phoenix.Socket, log: false

  channel "room:*", Stampede.TestChannel
  channel "presence:*", Stampede.TestPresenceChannel

  @impl true
  def connect(%{"token" => "invalid"}, _socket, _connect_info), do: :error
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end

defmodule Stampede.TestChannel do
  use Phoenix.Channel, log_join: false, log_handle_in: false

  @impl true
  def join("room:private", _payload, _socket), do: {:error, %{reason: "unauthorized"}}
  def join("room:" <> _name, payload, socket), do: {:ok, %{joined: true, echo: payload}, socket}

  @impl true
  def handle_in("ping", payload, socket), do: {:reply, {:ok, %{pong: payload}}, socket}
  def handle_in("fail", _payload, socket), do: {:reply, {:error, %{reason: "failed"}}, socket}
  def handle_in("silent", _payload, socket), do: {:noreply, socket}
  def handle_in("crash", _payload, _socket), do: raise("boom")

  def handle_in("shout", payload, socket) do
    broadcast!(socket, "shout", payload)
    {:noreply, socket}
  end

  def handle_in("bytes", {:binary, data}, socket), do: {:reply, {:ok, {:binary, data}}, socket}

  def handle_in("push_bytes", %{"data" => data}, socket) do
    push(socket, "bytes", {:binary, data})
    {:noreply, socket}
  end

  def handle_in("shout_bytes", %{"data" => data}, socket) do
    broadcast!(socket, "bytes", {:binary, data})
    {:noreply, socket}
  end
end

defmodule Stampede.TestPresence do
  use Phoenix.Presence, otp_app: :stampede, pubsub_server: Stampede.TestPubSub
end

# Tracks everyone who joins, as in the Phoenix.Presence docs.
defmodule Stampede.TestPresenceChannel do
  use Phoenix.Channel, log_join: false, log_handle_in: false

  alias Stampede.TestPresence

  @impl true
  def join("presence:" <> _room, %{"name" => name}, socket) do
    send(self(), :after_join)
    {:ok, assign(socket, :name, name)}
  end

  @impl true
  def handle_info(:after_join, socket) do
    {:ok, _ref} = TestPresence.track(socket, socket.assigns.name, %{})
    push(socket, "presence_state", TestPresence.list(socket))
    {:noreply, socket}
  end
end
