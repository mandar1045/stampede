defmodule Stampede.TestEndpoint do
  use Phoenix.Endpoint, otp_app: :stampede

  @session_options [store: :cookie, key: "_stampede_key", signing_salt: "stampede"]

  socket "/socket", Stampede.TestSocket, websocket: true, longpoll: false

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false

  plug Plug.Session, @session_options
  plug Stampede.TestRouter

  def socket_url do
    {:ok, {_ip, port}} = server_info(:http)
    "ws://127.0.0.1:#{port}/socket"
  end

  def page_url(path) do
    {:ok, {_ip, port}} = server_info(:http)
    "http://127.0.0.1:#{port}#{path}"
  end
end

defmodule Stampede.TestSocket do
  use Phoenix.Socket, log: false

  channel "room:*", Stampede.TestChannel

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
end
