defmodule Stampede.LiveViewTest do
  use ExUnit.Case, async: true

  alias Stampede.{HTTP, LiveView}

  defmodule Clicking do
    use Stampede.Scenario

    @impl true
    def run(_vu) do
      {:ok, view} = LiveView.connect(Stampede.TestEndpoint.page_url("/counter"))
      {:ok, nil} = LiveView.click(view, "inc")
    end
  end

  defp url(path), do: Stampede.TestEndpoint.page_url(path)

  describe "connect/2" do
    test "fetches the page and joins its LiveView" do
      assert {:ok, %LiveView{topic: "lv:phx-" <> _id} = view} = LiveView.connect(url("/counter"))
      assert {:ok, %{"count" => 0}} = LiveView.click(view, "state")
    end

    test "opens the socket with the page's cookies and CSRF token" do
      {:ok, view} = LiveView.connect(url("/counter"))

      assert {:ok, %{"visitor" => "jo"}} = LiveView.click(view, "state")
    end

    test "follows redirects to the LiveView" do
      assert {:ok, view} = LiveView.connect(url("/moved"))
      assert view.url == url("/counter")
    end

    test "keeps the cookies set by redirects" do
      {:ok, view} = LiveView.connect(url("/sign-in/sam"))

      assert {:ok, %{"visitor" => "sam"}} = LiveView.click(view, "state")
    end

    test "uses the session a VU signed in with over HTTP, when asked to" do
      {:ok, page} = HTTP.get(url("/counter"), cookies: true)
      user = %{"name" => "ada", "password" => "open sesame"}
      form = %{"_csrf_token" => HTTP.csrf_token(page), "user" => user}

      assert {:ok, %{status: 302}} = HTTP.post(url("/sign-in"), cookies: true, form: form)

      {:ok, view} = LiveView.connect(url("/counter"), cookies: true)
      assert {:ok, %{"visitor" => "ada"}} = LiveView.click(view, "state")

      {:ok, stranger} = LiveView.connect(url("/counter"))
      assert {:ok, %{"visitor" => "jo"}} = LiveView.click(stranger, "state")
    end

    test "adds the cookies it gets to the VU's, when asked to" do
      {:ok, view} = LiveView.connect(url("/sign-in/sam"), cookies: true)
      assert {:ok, %{"visitor" => "sam"}} = LiveView.click(view, "state")

      {:ok, again} = LiveView.connect(url("/counter"), cookies: true)
      assert {:ok, %{"visitor" => "sam"}} = LiveView.click(again, "state")
    end

    test "returns an error after too many redirects" do
      assert {:error, {:http_status, 302}} = LiveView.connect(url("/loop"))
      assert {:error, {:http_status, 302}} = LiveView.connect(url("/moved"), max_redirects: 0)
    end

    test "returns an error when the page has no LiveView" do
      assert {:error, :no_live_view} = LiveView.connect(url("/plain"))
    end

    test "follows LiveViews that redirect while mounting" do
      assert {:ok, view} = LiveView.connect(url("/redirecting"))
      assert view.url == url("/counter")

      assert {:error, {:live_redirect, %{"to" => "/counter"}}} =
               LiveView.connect(url("/redirecting"), max_redirects: 0)
    end

    test "leaves other messages in the caller's mailbox" do
      send(self(), :mine)
      {:ok, _view} = LiveView.connect(url("/counter"))

      assert_received :mine
    end

    test "raises on URLs that are not HTTP" do
      assert_raise ArgumentError, ~r"expected an http:// or https:// URL", fn ->
        LiveView.connect("ws://localhost:4000/counter")
      end
    end
  end

  describe "events" do
    setup do
      {:ok, view} = LiveView.connect(url("/counter"))
      %{view: view}
    end

    test "click/4 sends clicks", %{view: view} do
      assert {:ok, nil} = LiveView.click(view, "inc")
      assert {:ok, %{"count" => 1}} = LiveView.click(view, "state")
    end

    test "sends events to components with :target", %{view: view} do
      assert {:ok, %{"id" => "widget"}} = LiveView.click(view, "whoami", %{}, target: 1)
    end

    test "submit/4 and change/4 send nested form fields", %{view: view} do
      params = %{"user" => %{"name" => "jo smith", "tags" => ["a", "b"]}}

      assert {:ok, %{"user" => %{"name" => "jo smith", "tags" => ["a", "b"]}}} =
               LiveView.submit(view, "save", params)

      assert {:ok, %{"user" => %{"name" => "jo"}}} =
               LiveView.change(view, "save", %{user: %{name: "jo"}})
    end

    test "await/2 returns updates the LiveView sends on its own", %{view: view} do
      {:ok, nil} = LiveView.click(view, "later")

      assert {:ok, %{}} = LiveView.await(view)
      assert {:ok, %{"count" => 1}} = LiveView.click(view, "state")
    end

    @tag capture_log: true
    test "fails events the LiveView crashes on", %{view: view} do
      assert {:error, :channel_crashed} = LiveView.click(view, "crash")
    end

    test "close/1 closes the connection", %{view: view} do
      assert :ok = LiveView.close(view)
      refute Process.alive?(view.socket)
    end
  end

  describe "navigation" do
    setup do
      {:ok, view} = LiveView.connect(url("/counter"))
      %{view: view}
    end

    test "patch/3 runs handle_params and moves the view to the new URL", %{view: view} do
      assert {:ok, patched} = LiveView.patch(view, "/counter?page=2")

      assert patched.url == url("/counter?page=2")
      assert patched.socket == view.socket
      assert {:ok, %{"page" => "2"}} = LiveView.click(patched, "state")
    end

    test "patch/3 navigates when the URL belongs to another LiveView", %{view: view} do
      assert {:ok, other} = LiveView.patch(view, "/other")

      assert other.socket == view.socket
      assert {:ok, %{"view" => "other"}} = LiveView.click(other, "whoami")
    end

    test "navigate/3 joins the new LiveView over the same socket", %{view: view} do
      assert {:ok, other} = LiveView.navigate(view, "/other")

      assert other.url == url("/other")
      assert other.socket == view.socket
      assert {:ok, %{"view" => "other"}} = LiveView.click(other, "whoami")
    end

    @tag capture_log: true
    test "navigate/3 loads the page again across live sessions", %{view: view} do
      assert {:ok, other} = LiveView.navigate(view, "/elsewhere")

      assert other.socket != view.socket
      refute Process.alive?(view.socket)
      assert {:ok, %{"view" => "other"}} = LiveView.click(other, "whoami")
    end

    test "events return the navigation the LiveView asks for", %{view: view} do
      assert {:error, {:live_redirect, %{"to" => "/other"} = redirect}} =
               LiveView.click(view, "go")

      assert {:ok, other} = LiveView.navigate(view, redirect["to"])
      assert {:ok, %{"view" => "other"}} = LiveView.click(other, "whoami")
    end

    # LiveView closes the channel before it replies to a leave.
    test "leaving the LiveView's channel succeeds", %{view: view} do
      assert :ok = Stampede.Channels.leave(view.socket, view.topic)
    end

    test "events return full redirects", %{view: view} do
      assert {:error, {:redirect, %{"to" => "/plain"}}} = LiveView.click(view, "leave")
    end
  end

  describe "upload/4" do
    setup do
      {:ok, view} = LiveView.connect(url("/upload"))
      %{view: view}
    end

    defp file(name, size) do
      content = :crypto.strong_rand_bytes(size)
      hash = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)
      {%{name: name, content: content}, hash}
    end

    test "sends files in chunks for the LiveView to consume", %{view: view} do
      {photo, photo_hash} = file("me.jpg", 2_500)
      {icon, icon_hash} = file("icon.PNG", 999)

      assert :ok = LiveView.upload(view, "avatar", [photo, icon])

      assert {:ok, %{"title" => "Hi", "files" => files}} =
               LiveView.submit(view, "save", %{"title" => "Hi"})

      assert Enum.sort_by(files, & &1["name"]) == [
               %{
                 "name" => "icon.PNG",
                 "type" => "image/png",
                 "size" => 999,
                 "sha256" => icon_hash
               },
               %{
                 "name" => "me.jpg",
                 "type" => "image/jpeg",
                 "size" => 2_500,
                 "sha256" => photo_hash
               }
             ]
    end

    test "sends files to automatic uploads, of any type and size", %{view: view} do
      {document, hash} = file("report.bin", 70_000)

      assert :ok = LiveView.upload(view, "document", [document])

      assert {:ok, %{"documents" => [%{"size" => 70_000, "sha256" => ^hash}]}} =
               LiveView.submit(view, "save", %{})
    end

    test "replaces the file of an upload of one file", %{view: view} do
      {document, _hash} = file("report.bin", 100)
      empty = %{name: "empty", content: "", type: "application/x-empty"}

      assert :ok = LiveView.upload(view, "document", [document])
      assert :ok = LiveView.upload(view, "document", [empty])

      assert {:ok, %{"documents" => [replaced]}} = LiveView.submit(view, "save", %{})

      assert replaced == %{
               "name" => "empty",
               "type" => "application/x-empty",
               "size" => 0,
               "sha256" => sha256("")
             }
    end

    test "sends files to the component that renders the upload", %{view: view} do
      {photo, hash} = file("me.jpg", 10)

      assert :ok = LiveView.upload(view, "photo", [photo])

      assert {:ok, %{"files" => [%{"sha256" => ^hash}]}} =
               LiveView.submit(view, "save", %{}, target: 1)
    end

    test "returns the files the LiveView rejects", %{view: view} do
      {notes, _hash} = file("notes.txt", 10)
      {big, _hash} = file("big.jpg", 50_001)
      {photo, _hash} = file("me.jpg", 10)

      assert {:error, {:rejected, [{"notes.txt", "not_accepted"}]}} =
               LiveView.upload(view, "avatar", [notes])

      # The rejected file stays until the LiveView cancels it.
      assert {:error, {:rejected, [{"big.jpg", "too_large"}]}} =
               LiveView.upload(view, "avatar", [big])

      {:ok, view} = LiveView.connect(url("/upload"))

      assert {:error, {:rejected, [{"avatar", "too_many_files"}]}} =
               LiveView.upload(view, "avatar", [photo, photo, photo])
    end

    test "returns an error for uploads the page did not render", %{view: view} do
      assert {:error, {:no_upload, "missing"}} = LiveView.upload(view, "missing", [])

      {:ok, counter} = LiveView.connect(url("/counter"))
      assert {:error, {:no_upload, "avatar"}} = LiveView.upload(counter, "avatar", [])
    end

    test "raises on files without a name or content", %{view: view} do
      assert_raise ArgumentError, ~r/expected a file to be a map with a :name/, fn ->
        LiveView.upload(view, "avatar", ["me.jpg"])
      end
    end
  end

  defp sha256(content), do: :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

  defmodule Uploading do
    use Stampede.Scenario

    @impl true
    def run(_vu) do
      {:ok, view} = LiveView.connect(Stampede.TestEndpoint.page_url("/upload"))
      :ok = LiveView.upload(view, "avatar", [%{name: "me.jpg", content: "photo"}])
      {:ok, %{"files" => [_file]}} = LiveView.submit(view, "save", %{})
    end
  end

  test "records uploads inside a run" do
    result = Stampede.run(Uploading, vus: 2, duration: 1_000, graceful_stop: 10_000)

    assert result.errors == []
    assert result.metrics["live.upload"].count > 0
    refute Map.has_key?(result.metrics, "live.upload.errors")
  end

  defmodule Browsing do
    use Stampede.Scenario

    @impl true
    def run(_vu) do
      {:ok, view} = LiveView.connect(Stampede.TestEndpoint.page_url("/counter"))
      {:ok, view} = LiveView.patch(view, "/counter?page=2")
      {:ok, _view} = LiveView.navigate(view, "/other")
    end
  end

  test "records navigation metrics inside a run" do
    result = Stampede.run(Browsing, vus: 2, duration: 1_000, graceful_stop: 10_000)

    assert result.errors == []
    assert result.metrics["live.patch"].count > 0
    assert result.metrics["live.navigate"].count > 0

    assert for({name, _summary} <- result.metrics, String.ends_with?(name, ".errors"), do: name) ==
             []

    refute Map.has_key?(result.metrics, "channel.messages")
  end

  # Long enough for the first LiveView request of the test run, which loads
  # the server's modules and can take a few hundred milliseconds.
  test "records its metrics inside a run" do
    result = Stampede.run(Clicking, vus: 2, duration: 1_000)

    assert result.errors == []

    for name <- ["live.page", "live.join", "live.event", "ws.connect"] do
      assert %{type: :timing, count: count} = result.metrics[name]
      assert count > 0
    end
  end
end
