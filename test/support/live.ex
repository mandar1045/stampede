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
    live "/other", Stampede.TestOtherLive
    live "/redirecting", Stampede.TestRedirectLive
    live "/upload", Stampede.TestUploadLive
    get "/plain", Stampede.TestPageController, :plain
    get "/moved", Stampede.TestPageController, :moved
    get "/loop", Stampede.TestPageController, :loop
    get "/sign-in/:name", Stampede.TestPageController, :sign_in

    live_session :elsewhere do
      live "/elsewhere", Stampede.TestOtherLive
    end
  end

  scope "/api" do
    get "/hello", Stampede.TestApiController, :hello
    post "/echo", Stampede.TestApiController, :echo
    put "/echo", Stampede.TestApiController, :echo
    get "/port", Stampede.TestApiController, :port
    get "/fail", Stampede.TestApiController, :fail
    get "/close", Stampede.TestApiController, :close
    get "/echo-socket", Stampede.TestApiController, :echo_socket
    get "/events", Stampede.TestEventsController, :steady
    post "/events", Stampede.TestEventsController, :steady
    get "/events/tricky", Stampede.TestEventsController, :tricky
    get "/events/broken", Stampede.TestEventsController, :broken
    get "/events/limited", Stampede.TestEventsController, :limited
  end

  scope "/v1" do
    post "/chat/completions", Stampede.TestLLMController, :chat
  end

  defp put_visitor(conn, _opts) do
    if get_session(conn, "visitor"), do: conn, else: put_session(conn, "visitor", "jo")
  end
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
  def loop(conn, _params), do: redirect(conn, to: "/loop")

  def sign_in(conn, %{"name" => name}) do
    conn
    |> Plug.Conn.put_session("visitor", name)
    |> redirect(to: "/counter")
  end
end

defmodule Stampede.TestApiController do
  use Phoenix.Controller, formats: [:json]

  def hello(conn, _params), do: json(conn, %{hello: "world"})
  def echo(conn, params), do: json(conn, %{method: conn.method, params: params})
  def fail(conn, _params), do: conn |> put_status(500) |> json(%{error: "failed"})

  # The client's port tells requests sent on the same connection apart.
  def port(conn, _params), do: text(conn, Integer.to_string(Plug.Conn.get_peer_data(conn).port))

  def close(conn, _params) do
    conn
    |> Plug.Conn.put_resp_header("connection", "close")
    |> text("bye")
  end

  def echo_socket(conn, _params) do
    conn
    |> WebSockAdapter.upgrade(Stampede.TestEchoSocket, nil, [])
    |> halt()
  end
end

# Echoes every frame, after a welcome, and closes when asked to.
defmodule Stampede.TestEchoSocket do
  @behaviour WebSock

  @impl true
  def init(state), do: {:push, {:text, "welcome"}, state}

  @impl true
  def handle_in({"close", [opcode: :text]}, state) do
    {:stop, :normal, {1000, "bye"}, [{:text, "closing"}], state}
  end

  def handle_in({"ping me", [opcode: :text]}, state), do: {:push, {:ping, "hi"}, state}
  def handle_in({data, [opcode: opcode]}, state), do: {:push, {opcode, data}, state}

  @impl true
  def handle_control({data, [opcode: :pong]}, state), do: {:push, {:text, "pong " <> data}, state}
  def handle_control(_frame, state), do: {:ok, state}

  @impl true
  def handle_info(_message, state), do: {:ok, state}
end

defmodule Stampede.TestWidget do
  use Phoenix.LiveComponent

  @impl true
  def render(assigns), do: ~H"<p phx-target={@myself}>widget</p>"

  @impl true
  def handle_event("whoami", _params, socket), do: {:reply, %{id: socket.assigns.id}, socket}
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
    <.live_component module={Stampede.TestWidget} id="widget" />
    """
  end

  @impl true
  def handle_params(params, _url, socket), do: {:noreply, assign(socket, page: params["page"])}

  @impl true
  def handle_event("inc", _params, socket), do: {:noreply, update(socket, :count, &(&1 + 1))}
  def handle_event("crash", _params, _socket), do: raise("boom")
  def handle_event("go", _params, socket), do: {:noreply, push_navigate(socket, to: "/other")}
  def handle_event("leave", _params, socket), do: {:noreply, redirect(socket, to: "/plain")}

  def handle_event("state", _params, socket) do
    %{count: count, name: name, page: page, connect_session: session} = socket.assigns
    visitor = session && session["visitor"]
    {:reply, %{count: count, name: name, page: page, visitor: visitor}, socket}
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

defmodule Stampede.TestOtherLive do
  use Phoenix.LiveView, log: false

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns), do: ~H"<p>other</p>"

  @impl true
  def handle_event("whoami", _params, socket), do: {:reply, %{view: "other"}, socket}
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

defmodule Stampede.TestUploadLive do
  use Phoenix.LiveView, log: false

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(form: to_form(%{"title" => ""}))
     |> allow_upload(:avatar,
       accept: ~w(.jpg .png),
       max_entries: 2,
       max_file_size: 50_000,
       chunk_size: 1_000
     )
     |> allow_upload(:document, accept: :any, auto_upload: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.form for={@form} phx-change="validate" phx-submit="save">
      <input type="text" name="title" />
      <.live_file_input upload={@uploads.avatar} />
      <.live_file_input upload={@uploads.document} />
    </.form>
    <.live_component module={Stampede.TestUploadWidget} id="widget" />
    """
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("save", params, socket) do
    files = consume_uploaded_entries(socket, :avatar, &uploaded/2)
    documents = consume_uploaded_entries(socket, :document, &uploaded/2)
    {:reply, %{title: params["title"], files: files, documents: documents}, socket}
  end

  @doc false
  def uploaded(%{path: path}, entry) do
    content = File.read!(path)
    hash = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

    {:ok,
     %{name: entry.client_name, type: entry.client_type, size: byte_size(content), sha256: hash}}
  end
end

defmodule Stampede.TestUploadWidget do
  use Phoenix.LiveComponent

  @impl true
  def mount(socket), do: {:ok, allow_upload(socket, :photo, accept: :any)}

  @impl true
  def render(assigns) do
    ~H"""
    <form phx-submit="save" phx-target={@myself}>
      <.live_file_input upload={@uploads.photo} />
    </form>
    """
  end

  @impl true
  def handle_event("save", _params, socket) do
    files = consume_uploaded_entries(socket, :photo, &Stampede.TestUploadLive.uploaded/2)
    {:reply, %{files: files}, socket}
  end
end
