# Pages behind a login

Most pages worth load testing are behind a login. A browser gets to them by
signing in, which sets a session cookie that every later request sends.
`Stampede.LiveView.connect/2` does the same: it follows redirects and keeps
the cookies they set. So a route that signs a user in and redirects to the
page under test is all a load test needs.

## A sign-in route for load tests

Signing in through the real login form needs a password for every user, or
an email with a magic link that a load test can't read. A route that signs
in a test user directly is much simpler. This one works with the authentication
that `mix phx.gen.auth` generates in Phoenix 1.8:

```elixir
# lib/my_app_web/controllers/load_test_controller.ex
defmodule MyAppWeb.LoadTestController do
  use MyAppWeb, :controller

  alias MyApp.Accounts
  alias MyAppWeb.UserAuth

  # Signs in the user with this email, creating it the first time, and
  # sends them on to `to`.
  def sign_in(conn, %{"email" => email, "to" => to}) do
    {:ok, user} =
      case Accounts.get_user_by_email(email) do
        nil -> Accounts.register_user(%{email: email})
        user -> {:ok, user}
      end

    conn
    |> put_session(:user_return_to, to)
    |> UserAuth.log_in_user(user)
  end
end
```

With password authentication, give `register_user/1` a password too.

Please don't skip this part: anyone who can reach this route can sign in
as anyone, so it must never reach production. Mount it only when a setting allows it, which
`Application.compile_env/3` checks at compile time, leaving the route out of
production builds entirely:

```elixir
# lib/my_app_web/router.ex
if Application.compile_env(:my_app, :load_test_routes, false) do
  scope "/load-test", MyAppWeb do
    pipe_through :browser

    get "/sign-in", LoadTestController, :sign_in
  end
end
```

```elixir
# config/dev.exs
config :my_app, load_test_routes: true
```

## Signing in from a scenario

Each VU signs in as a user of its own, then uses the page:

```elixir
defmodule MyApp.Load.Dashboard do
  use Stampede.Scenario

  @impl true
  def options do
    [
      stages: [{[second: 30], 200}, {[minute: 2], 200}, {[second: 10], 0}],
      thresholds: [{"live.join", p95: 500}, {"iteration.errors", count: 0}]
    ]
  end

  @impl true
  def run(vu) do
    query = URI.encode_query(email: "load-#{vu.id}@example.com", to: "/dashboard")
    {:ok, view} = Stampede.LiveView.connect("http://localhost:4000/load-test/sign-in?" <> query)

    {:ok, _reply} = Stampede.LiveView.click(view, "refresh")
    Process.sleep(5_000)
  end
end
```

`connect/2` requests the sign-in route, follows its redirect to `/dashboard`
with the session cookie, and joins the LiveView with that cookie and the
page's CSRF token, as a browser would. `"live.page"` times the whole page
load, the sign-in included.

## Tokens for sockets and APIs

Channels and APIs often check a token rather than a cookie. When your socket
verifies a `Phoenix.Token`, sign one per VU with your endpoint's secret.
`mix stampede.run` loads your application's configuration, so the secret is
there:

```elixir
defmodule MyApp.Load.Chat do
  use Stampede.Scenario

  @impl true
  def setup(_opts) do
    Application.fetch_env!(:my_app, MyAppWeb.Endpoint)[:secret_key_base]
  end

  @impl true
  def run(vu) do
    token = Phoenix.Token.sign(vu.data, "user socket", vu.id)
    {:ok, socket} = Stampede.Channels.connect("ws://localhost:4000/socket", params: %{token: token})
    {:ok, _reply} = Stampede.Channels.join(socket, "room:lobby")
    Process.sleep(10_000)
  end
end
```

`Stampede.HTTP` takes the token as a header instead:

```elixir
Stampede.HTTP.get("http://localhost:4000/api/orders", headers: [{"authorization", "Bearer " <> token}])
```
