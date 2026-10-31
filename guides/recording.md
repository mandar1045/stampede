# Recording a session

Writing a LiveView scenario by hand means digging out event names and form
fields. With `mix stampede.record`, you use your app once in the browser, and
Stampede writes the scenario.

## Recording

Add Stampede to your project if you haven't, then run this in your Phoenix app:

```console
$ mix stampede.record Checkout
```

That starts your app. Open it in a browser, do what a user would do, and press
Enter in the terminal. You get `loadtest/checkout.exs`, ready to run:

```console
$ mix stampede.run loadtest/checkout.exs
```

## What gets recorded

| You do | The scenario does |
|---|---|
| Open a LiveView page | `Stampede.LiveView.connect/2` |
| Follow a `patch` or `navigate` link | `Stampede.LiveView.patch/3` or `navigate/3` |
| Click something with `phx-click` | `Stampede.LiveView.click/4`, with its values |
| Type in a form with `phx-change` | `Stampede.LiveView.change/4` |
| Submit a form with `phx-submit` | `Stampede.LiveView.submit/4` |
| Click in a LiveComponent | The same, with its `:target` |
| Upload a file | `Stampede.LiveView.upload/4` |
| Use a channel | `Stampede.Channels.connect/2`, `join/4` and `cast/4` |
| Load a plain page | `Stampede.HTTP.get/2` |
| Send a form or JSON to a controller | `Stampede.HTTP.post/2` and friends, with what it sent |
| Stop and think | `Process.sleep/1`, up to 30 seconds |

Typing sends a change for every key, and your server really does that work. So
the scenario keeps them, as a loop that repeats the last change as many times:

```elixir
# You typed here, which sent 22 changes.
for _change <- 1..22 do
  {:ok, _reply} =
    Stampede.LiveView.change(view, "validate", %{"user" => %{"email" => "jo@example.com"}})
end
```

## Signing in

Start recording before you sign in, and sign in as you normally would. The form
post becomes a real step, which loads the page again for a fresh CSRF token, then
sends the form with it:

```elixir
def run(_vu) do
  # A new visitor each time, or they'd still be signed in.
  Stampede.HTTP.clear_cookies()

  {:ok, %{url: "http://localhost:4000/users/log-in"} = view} =
    Stampede.LiveView.connect("http://localhost:4000/users/log-in", cookies: true)

  {:ok, page} = Stampede.HTTP.get("http://localhost:4000/users/log-in", cookies: true)
  # Put real values where it says CHANGE_ME, or this will be turned down.
  {:ok, %{status: 302}} =
    Stampede.HTTP.post("http://localhost:4000/users/log-in",
      cookies: true,
      form: %{
        "_csrf_token" => Stampede.HTTP.csrf_token(page),
        "user" => %{"email" => "jo@example.com", "password" => "CHANGE_ME"}
      }
    )

  {:ok, %{url: "http://localhost:4000/dashboard"} = view} =
    Stampede.LiveView.connect("http://localhost:4000/dashboard", cookies: true)

  :ok = Stampede.LiveView.close(view)
end
```

With `cookies: true`, each VU keeps its own session across `Stampede.HTTP` and
`Stampede.LiveView`, as one browser would. The scenario also checks each page
ends up where it did when you recorded it. Most apps answer a wrong password
with a redirect back to the sign-in page, which looks fine from the outside, so
that check is what tells you the sign-in failed.

The password goes where it says `"CHANGE_ME"`, and I'd read it from an
environment variable rather than commit it. Hashing a password takes a lot of
CPU on purpose, so a test that signs in on every iteration spends most of its
time there. If that's not what you're testing, see the
[sign-in route in the login guide](login.md#a-sign-in-route-for-load-tests).

## What stays out of the file

Anything whose name looks sensitive becomes `"CHANGE_ME"`: passwords, tokens,
secrets, API keys and card numbers, in forms, in JSON, in channel messages and in
URLs. CSRF tokens are dropped. Uploaded files aren't kept either, only their name,
size and type, and the scenario sends random bytes of the same size.

Everything else is kept as you typed it, like an email address, so read the file
before you commit it. The matching goes by name, so a field called `pin` or
`code` would get through.

## Making it your own

The recording is one person doing one thing, so a few edits make it a better
load test:

  * **Replace `"CHANGE_ME"`** with something that works, or a form that needs a
    real password will fail.
  * **Give each VU its own data.** `run/1` gets the VU, so
    `"email" => "user#{vu.id}@example.com"` stops every VU from being the same
    person. Rename `_vu` to `vu` when you do.
  * **Set the load** in `options/0`. It's 50 VUs to start with.
  * **Change `cast` to `push`** for channel events that reply. The recorder can't
    tell if they do, and `cast` doesn't wait, so it won't time them.

## What it can't do yet

  * **Signing in with an emailed link,** or with a third party like Google. The
    scenario can't read your email, so use the
    [sign-in route in the login guide](login.md#a-sign-in-route-for-load-tests).
  * **File uploads to controllers.** A multipart POST shows up as a comment, as
    does anything else that isn't a form or JSON.
  * **Headers,** like `authorization`. They aren't recorded, so add them to the
    request.
  * **Connect params.** A channel socket's `:params`, such as a token, aren't
    visible on the server, so add them to `Stampede.Channels.connect/2`.

It records everything that happens in the app while it runs, so don't use it
somewhere other people are using the app at the same time.
