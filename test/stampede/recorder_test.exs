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

  test "records plain GET requests, and leaves other requests as a comment" do
    steps =
      record(fn ->
        {:ok, %{status: 200}} = Stampede.HTTP.get(url("/plain"))
        {:ok, _response} = Stampede.HTTP.post(url("/api/echo"), json: %{a: 1})
      end)

    assert kinds(steps) == [:http, :http]

    scenario = Recorder.to_scenario(steps, Plain)
    assert scenario =~ ~r/Stampede.HTTP.get\("http.*\/plain"\)/
    assert scenario =~ ~r/# POST http.*\/api\/echo happened here/
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
    result = Stampede.run(module, stages: nil, vus: 2, duration: 1_000)

    assert result.errors == []
    assert result.metrics["live.join"].count >= 2
    assert result.metrics["live.event"].count >= 4
  end
end
