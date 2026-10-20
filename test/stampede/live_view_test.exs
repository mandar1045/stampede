defmodule Stampede.LiveViewTest do
  use ExUnit.Case, async: true

  alias Stampede.LiveView

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

    test "returns an error after too many redirects" do
      assert {:error, {:http_status, 302}} = LiveView.connect(url("/loop"))
      assert {:error, {:http_status, 302}} = LiveView.connect(url("/moved"), max_redirects: 0)
    end

    test "returns an error when the page has no LiveView" do
      assert {:error, :no_live_view} = LiveView.connect(url("/plain"))
    end

    test "returns the reply when the LiveView refuses the join" do
      assert {:error, %{"live_redirect" => %{"to" => "/counter"}}} =
               LiveView.connect(url("/redirecting"))
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
