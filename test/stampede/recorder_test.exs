defmodule Stampede.RecorderTest do
  # The recorder hears every LiveView on the node.
  use ExUnit.Case, async: false

  alias Stampede.{LiveView, Recorder}

  defp url(path), do: Stampede.TestEndpoint.page_url(path)

  defp record(fun) do
    {:ok, recorder} = Recorder.start()
    fun.()
    Process.sleep(50)
    Recorder.stop(recorder)
  end

  defp kinds(steps), do: Enum.map(steps, & &1.kind)

  test "records pages, navigation, patches and events, in order" do
    steps =
      record(fn ->
        {:ok, view} = LiveView.connect(url("/counter"))
        {:ok, nil} = LiveView.click(view, "inc")
        {:ok, view} = LiveView.patch(view, "/counter?page=2")
        {:ok, view} = LiveView.navigate(view, "/other")
        :ok = LiveView.close(view)
      end)

    assert kinds(steps) == [:open, :click, :patch, :navigate]
    assert [%{url: "http://" <> _}, %{event: "inc", params: %{}}, %{url: patched}, _] = steps
    assert patched =~ "/counter?page=2"
  end

  test "tells forms from clicks, and keeps their values" do
    steps =
      record(fn ->
        {:ok, view} = LiveView.connect(url("/counter"))
        {:ok, _reply} = LiveView.click(view, "inc", %{"value" => "3", "id" => "7"})
        {:ok, _reply} = LiveView.change(view, "inc", %{"_target" => "user[name]", "name" => "jo"})
        {:ok, _reply} = LiveView.submit(view, "save", %{"user" => %{"name" => "jo"}})
        :ok = LiveView.close(view)
      end)

    assert [_, click, change, submit] = steps
    assert %{kind: :click, params: %{"id" => "7", "value" => "3"}} = click
    assert %{kind: :change, params: %{"name" => "jo"}} = change
    refute Map.has_key?(change.params, "_target")
    assert %{kind: :submit, event: "save", params: %{"user" => %{"name" => "jo"}}} = submit
  end

  test "never keeps passwords or tokens" do
    steps =
      record(fn ->
        {:ok, view} = LiveView.connect(url("/counter"))

        {:ok, _reply} =
          LiveView.submit(view, "save", %{
            "user" => %{"name" => "jo", "password" => "hunter2", "api_key" => "abc"},
            "_csrf_token" => "xyz",
            "card_number" => "4242"
          })

        :ok = LiveView.close(view)
      end)

    assert [_, %{params: params}] = steps

    assert params == %{
             "user" => %{"name" => "jo", "password" => "CHANGE_ME", "api_key" => "CHANGE_ME"},
             "card_number" => "CHANGE_ME"
           }

    scenario = Recorder.to_scenario(steps, Secret)
    refute scenario =~ "hunter2"
    refute scenario =~ "4242"
  end

  test "records requests with what they sent, and what they got back" do
    steps =
      record(fn ->
        {:ok, %{status: 200}} = Stampede.HTTP.get(url("/plain"))
        {:ok, _response} = Stampede.HTTP.post(url("/api/echo"), json: %{a: 1})
        {:ok, _response} = Stampede.HTTP.put(url("/api/echo"), json: [1, 2])
      end)

    assert kinds(steps) == [:http, :http, :http]

    scenario = Recorder.to_scenario(steps, Plain)
    assert scenario =~ "Stampede.HTTP.clear_cookies()"

    assert scenario =~
             ~r/\{:ok, %\{status: 200\}\} =\s+Stampede.HTTP.get\("http.*\/plain", cookies: true\)/

    assert scenario =~
             ~r/\{:ok, %\{status: 200\}\} =\s+Stampede.HTTP.post\("http.*\/api\/echo", cookies: true, json: %\{"a" => 1\}\)/

    assert scenario =~ ~r/Stampede.HTTP.put\("http.*\/api\/echo", cookies: true, json: \[1, 2\]\)/
  end

  test "leaves cookies out when nothing needs them" do
    steps = record(fn -> {:ok, _response} = Stampede.HTTP.get(url("/plain")) end)
    scenario = Recorder.to_scenario(steps, Plain)

    refute scenario =~ "cookies"
    assert scenario =~ ~r/Stampede.HTTP.get\("http.*\/plain"\)/
  end

  test "leaves a request it can't replay as a comment" do
    steps =
      record(fn ->
        {:ok, _response} =
          Stampede.HTTP.post(url("/api/echo"),
            headers: [{"content-type", "multipart/form-data; boundary=x"}],
            body: "--x--"
          )
      end)

    scenario = Recorder.to_scenario(steps, Plain)
    assert scenario =~ ~r/# POST http.*\/api\/echo happened here/
    refute scenario =~ "clear_cookies"
  end

  defp sign_in do
    {:ok, page} = Stampede.HTTP.get(url("/counter"), cookies: true)
    token = Stampede.HTTP.csrf_token(page)

    {:ok, %{status: 302}} =
      Stampede.HTTP.post(url("/sign-in"),
        cookies: true,
        headers: [{"referer", url("/counter?from=form&token=abc")}],
        form: %{
          "_csrf_token" => token,
          "user" => %{"name" => "ada", "password" => "open sesame"}
        }
      )

    {:ok, view} = LiveView.connect(url("/counter"), cookies: true)
    :ok = LiveView.close(view)
    Stampede.HTTP.clear_cookies()
  end

  test "writes a sign-in that works, without the password" do
    steps = record(&sign_in/0)
    scenario = Recorder.to_scenario(steps, Stampede.RecordedSignIn)

    refute scenario =~ "open sesame"
    refute scenario =~ "abc"
    assert scenario =~ ~s|"_csrf_token" => Stampede.HTTP.csrf_token(page)|
    assert scenario =~ "Put real values where it says CHANGE_ME"
    assert scenario =~ ~r/\{:ok, %\{url: "http.*\/counter"\} = view\} =/
    assert scenario =~ ~r/Stampede.LiveView.connect\("http.*\/counter", cookies: true\)/

    # The token and the session come from the VU's own requests each time.
    working =
      String.replace(scenario, ~s("password" => "CHANGE_ME"), ~s("password" => "open sesame"))

    [{module, _binary}] = Code.compile_string(working)

    result =
      Stampede.run(module,
        stages: nil,
        vus: 2,
        duration: 300,
        graceful_stop: 10_000,
        thresholds: []
      )

    assert result.metrics["iteration"].count >= 2
    refute Map.has_key?(result.metrics, "iteration.errors")
    :code.purge(module)
    :code.delete(module)

    # A wrong password shows up as an error, rather than as a fast sign-in.
    [{module, _binary}] = Code.compile_string(scenario)

    result =
      Stampede.run(module,
        stages: nil,
        vus: 1,
        duration: 100,
        graceful_stop: 10_000,
        thresholds: []
      )

    assert result.metrics["iteration.errors"].count >= 1
    :code.purge(module)
    :code.delete(module)
  end

  test "sends the token in a header when that's how the app did" do
    steps =
      record(fn ->
        {:ok, page} = Stampede.HTTP.get(url("/counter"), cookies: true)

        {:ok, _response} =
          Stampede.HTTP.post(url("/api/echo"),
            cookies: true,
            headers: [
              {"referer", url("/counter")},
              {"x-csrf-token", Stampede.HTTP.csrf_token(page)}
            ],
            json: %{a: 1}
          )

        Stampede.HTTP.clear_cookies()
      end)

    assert Recorder.to_scenario(steps, Plain) =~
             ~s|headers: [{"x-csrf-token", Stampede.HTTP.csrf_token(page)}]|
  end

  test "keeps secrets out of nested forms and lists" do
    steps =
      record(fn ->
        {:ok, _response} =
          Stampede.HTTP.post(url("/api/echo"),
            json: %{
              users: [%{name: "ada", password: "kept-in-a-list"}],
              secret: %{value: "kept-in-a-map"},
              tokens: ["list-of-secrets"]
            }
          )
      end)

    scenario = Recorder.to_scenario(steps, Plain)
    assert scenario =~ "ada"
    for secret <- ~w(kept-in-a-list kept-in-a-map list-of-secrets), do: refute(scenario =~ secret)
  end

  test "records events sent to components" do
    steps =
      record(fn ->
        {:ok, view} = LiveView.connect(url("/counter"))
        {:ok, _reply} = LiveView.click(view, "whoami", %{}, target: 1)
        :ok = LiveView.close(view)
      end)

    assert [_, %{kind: :click, event: "whoami", target: 1}] = steps
    assert Recorder.to_scenario(steps, Widget) =~ ~s(click(view, "whoami", %{}, target: 1\))
  end

  test "keeps your pauses, without the long ones" do
    steps = [
      %{kind: :open, url: "http://localhost/a", at: 0},
      %{kind: :click, event: "a", params: %{}, target: nil, at: 40},
      %{kind: :click, event: "b", params: %{}, target: nil, at: 2_340},
      %{kind: :click, event: "c", params: %{}, target: nil, at: 500_000}
    ]

    scenario = Recorder.to_scenario(steps, Paused)

    assert scenario =~ ~r/connect\(.*\n\s+\{:ok, _reply\} = Stampede.LiveView.click\(view, "a"\)/
    assert scenario =~ "Process.sleep(2300)"
    assert scenario =~ "Process.sleep(30000)"
  end

  test "keeps secrets out of URLs" do
    steps =
      record(fn ->
        {:ok, view} = LiveView.connect(url("/counter?token=abc123&page=1"))
        {:ok, view} = LiveView.patch(view, "/counter?page=2&api_key=abc456")
        :ok = LiveView.close(view)
        {:ok, _response} = Stampede.HTTP.get(url("/plain?password=abc789"))
      end)

    scenario = Recorder.to_scenario(steps, Urls)

    refute scenario =~ "abc"
    assert scenario =~ "token=CHANGE_ME&page=1"
    assert scenario =~ "page=2&api_key=CHANGE_ME"
    assert scenario =~ "password=CHANGE_ME"
  end

  test "turns typing into a loop, with as many changes" do
    change = fn at, email ->
      %{kind: :change, event: "validate", params: %{"email" => email}, target: nil, at: at}
    end

    steps = [
      %{kind: :open, url: "http://localhost/a", at: 0},
      change.(1_000, "j"),
      change.(1_300, "jo"),
      change.(1_600, "jo@"),
      %{kind: :submit, event: "save", params: %{"email" => "jo@"}, target: nil, at: 3_000}
    ]

    scenario = Recorder.to_scenario(steps, Typing)

    assert scenario =~ "# You typed here, which sent 3 changes."
    assert scenario =~ "for _change <- 1..3 do"
    assert scenario =~ "Process.sleep(300)"
    assert scenario =~ ~s(%{"email" => "jo@"})
    refute scenario =~ ~s(%{"email" => "jo"})
    assert scenario =~ "Process.sleep(1400)"
  end

  test "records uploads by their name, size and type, not their content" do
    photo = %{name: "me.png", content: "secret pixels", type: "image/png"}

    steps =
      record(fn ->
        {:ok, view} = LiveView.connect(url("/upload"))
        :ok = LiveView.upload(view, "avatar", [photo])
        {:ok, _reply} = LiveView.submit(view, "save", %{"title" => "Hi"})
        :ok = LiveView.close(view)
      end)

    assert kinds(steps) == [:open, :upload, :submit]
    assert [_, %{name: "avatar", files: [%{name: "me.png", size: 13}]}, _] = steps

    source = Recorder.to_scenario(steps, Stampede.RecorderTest.Uploaded)
    refute source =~ "secret pixels"
    assert source =~ ":crypto.strong_rand_bytes(13)"

    [{module, _binary}] = Code.compile_string(source)
    result = Stampede.run(module, stages: nil, vus: 1, duration: 500, graceful_stop: 10_000)

    assert result.errors == []
    assert result.metrics["live.upload"].count >= 1
  end

  test "records Channels, without LiveView's own" do
    steps =
      record(fn ->
        {:ok, view} = LiveView.connect(url("/counter"))
        :ok = LiveView.close(view)
        {:ok, socket} = Stampede.Channels.connect(Stampede.TestEndpoint.socket_url())

        {:ok, _reply} =
          Stampede.Channels.join(socket, "room:lobby", %{"token" => "abc", "a" => 1})

        {:ok, _reply} =
          Stampede.Channels.push(socket, "room:lobby", "ping", %{"password" => "abc"})
      end)

    assert kinds(steps) == [:open, :channel, :join, :push]

    source = Recorder.to_scenario(steps, Stampede.RecorderTest.Chatting)
    refute source =~ "abc"
    assert source =~ ~s(Stampede.Channels.join(socket, "room:lobby")
    assert source =~ ~s("token" => "CHANGE_ME")
    assert source =~ "cast doesn't wait for a reply"

    # The endpoint's configured port isn't the one the test server got.
    source =
      Regex.replace(~r/ws:\/\/[^"]+/, source, Stampede.TestEndpoint.socket_url(), global: true)

    [{module, _binary}] = Code.compile_string(source)
    result = Stampede.run(module, stages: nil, vus: 1, duration: 500, graceful_stop: 10_000)

    assert result.errors == []
    assert result.metrics["channel.join"].count >= 1
  end

  # Records a session, then runs what it wrote against the same app.
  test "writes a scenario that does the same thing" do
    steps =
      record(fn ->
        {:ok, view} = LiveView.connect(url("/counter"))
        {:ok, nil} = LiveView.click(view, "inc")
        {:ok, _reply} = LiveView.submit(view, "save", %{"user" => %{"name" => "jo"}})
        {:ok, view} = LiveView.patch(view, "/counter?page=2")
        {:error, {:live_redirect, _opts}} = LiveView.click(view, "go")
        {:ok, view} = LiveView.navigate(view, "/other")
        {:ok, %{"view" => "other"}} = LiveView.click(view, "whoami")
        :ok = LiveView.close(view)
      end)

    assert kinds(steps) == [:open, :click, :submit, :patch, :click, :navigate, :click]

    source = Recorder.to_scenario(steps, Stampede.RecorderTest.Recorded)
    assert IO.iodata_to_binary([Code.format_string!(source), "\n"]) == source

    [{module, _binary}] = Code.compile_string(source)
    result = Stampede.run(module, stages: nil, vus: 2, duration: 1_000, graceful_stop: 10_000)

    assert result.errors == []
    assert result.metrics["live.join"].count >= 2
    assert result.metrics["live.event"].count >= 4
  end
end
