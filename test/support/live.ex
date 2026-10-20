defmodule Stampede.TestRouter do
  use Phoenix.Router

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :fetch_session
    plug :put_visitor
    plug :protect_from_forgery
    plug :put_root_layout, html: {Stampede.TestLayouts, :root}
  end

  scope "/" do
    pipe_through :browser

    live "/counter", Stampede.TestCounterLive
    live "/redirecting", Stampede.TestRedirectLive
    get "/plain", Stampede.TestPageController, :plain
    get "/moved", Stampede.TestPageController, :moved
  end

  defp put_visitor(conn, _opts), do: put_session(conn, "visitor", "jo")
end

defmodule Stampede.TestLayouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <html>
      <head>
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end
end

defmodule Stampede.TestPageController do
  use Phoenix.Controller, formats: [:html]

  def plain(conn, _params), do: html(conn, "<p>no LiveView here</p>")
  def moved(conn, _params), do: redirect(conn, to: "/counter")
end

defmodule Stampede.TestCounterLive do
  use Phoenix.LiveView, log: false

  @impl true
  def mount(_params, _session, socket) do
    connect_session = if connected?(socket), do: get_connect_info(socket, :session)
    {:ok, assign(socket, count: 0, name: nil, connect_session: connect_session)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <p>count: {@count}</p>
    <p>name: {@name}</p>
    """
  end

  @impl true
  def handle_event("inc", _params, socket), do: {:noreply, update(socket, :count, &(&1 + 1))}
  def handle_event("crash", _params, _socket), do: raise("boom")

  def handle_event("state", _params, socket) do
    %{count: count, name: name, connect_session: session} = socket.assigns
    {:reply, %{count: count, name: name, visitor: session && session["visitor"]}, socket}
  end

  def handle_event("save", %{"user" => user}, socket) do
    {:reply, %{user: user}, assign(socket, name: user["name"])}
  end

  def handle_event("later", _params, socket) do
    send(self(), :inc)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:inc, socket), do: {:noreply, update(socket, :count, &(&1 + 1))}
end

defmodule Stampede.TestRedirectLive do
  use Phoenix.LiveView, log: false

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: {:ok, push_navigate(socket, to: "/counter")},
      else: {:ok, socket}
  end

  @impl true
  def render(assigns), do: ~H"<p>redirecting</p>"
end
