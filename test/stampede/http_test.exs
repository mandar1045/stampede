defmodule Stampede.HTTPTest do
  use ExUnit.Case, async: true

  alias Stampede.HTTP

  defmodule Calling do
    use Stampede.Scenario

    @impl true
    def run(_vu) do
      {:ok, %{status: 200}} = HTTP.get(Stampede.TestEndpoint.page_url("/api/hello"))
      {:ok, %{status: 500}} = HTTP.get(Stampede.TestEndpoint.page_url("/api/fail"))
      {:ok, _response} = HTTP.get(Stampede.TestEndpoint.page_url("/api/hello"), metric: "hello")
    end
  end

  defp url(path), do: Stampede.TestEndpoint.page_url(path)

  test "get/2 returns the status, headers and body" do
    assert {:ok, %{status: 200, headers: headers, body: body}} = HTTP.get(url("/api/hello"))
    assert JSON.decode!(body) == %{"hello" => "world"}
    assert {"content-type", "application/json; charset=utf-8"} in headers
  end

  test "sends JSON bodies" do
    assert {:ok, %{status: 200, body: body}} = HTTP.post(url("/api/echo"), json: %{title: "Hi"})
    assert JSON.decode!(body) == %{"method" => "POST", "params" => %{"title" => "Hi"}}

    assert {:ok, %{body: body}} =
             HTTP.put(url("/api/echo"),
               body: ~s({"n":1}),
               headers: [{"content-type", "application/json"}]
             )

    assert JSON.decode!(body)["params"] == %{"n" => 1}
  end

  test "sends forms as a browser would" do
    form = %{"user" => %{"name" => "jo", "tags" => ["a", "b"]}, "n" => 1}
    {:ok, %{body: body}} = HTTP.post(url("/api/echo"), form: form)

    assert JSON.decode!(body)["params"] == %{
             "user" => %{"name" => "jo", "tags" => ["a", "b"]},
             "n" => "1"
           }
  end

  describe "cookies" do
    defp sent_cookie(opts \\ [cookies: true]) do
      {:ok, %{body: body}} = HTTP.get(url("/api/cookies"), opts)
      JSON.decode!(body)["cookie"]
    end

    defp set_cookie(name, value) do
      {:ok, %{status: 200}} =
        HTTP.get(url("/api/cookies/set?name=#{name}&value=#{value}"), cookies: true)
    end

    test "are sent back on later requests, when asked for" do
      set_cookie("flavour", "ginger")
      set_cookie("size", "large")

      assert sent_cookie() == "flavour=ginger; size=large"
      assert sent_cookie([]) == ""
    end

    test "are replaced by a new value, and removed when the server deletes them" do
      set_cookie("flavour", "ginger")
      set_cookie("flavour", "oat")
      set_cookie("size", "large")
      assert sent_cookie() == "flavour=oat; size=large"

      {:ok, _response} = HTTP.get(url("/api/cookies/forget?name=flavour"), cookies: true)
      assert sent_cookie() == "size=large"
    end

    test "go alongside a cookie header of your own" do
      set_cookie("flavour", "ginger")

      assert sent_cookie(cookies: true, headers: [{"cookie", "mine=1"}]) ==
               "mine=1; flavour=ginger"
    end

    test "belong to one VU and one host, and clear_cookies/0 forgets them" do
      set_cookie("flavour", "ginger")

      other = Task.async(fn -> sent_cookie() end)
      assert Task.await(other) == ""

      other_host = String.replace(url("/api/cookies"), "127.0.0.1", "localhost")
      {:ok, %{body: body}} = HTTP.get(other_host, cookies: true)
      assert JSON.decode!(body)["cookie"] == ""

      assert HTTP.clear_cookies() == :ok
      assert sent_cookie() == ""
    end
  end

  describe "csrf_token/1" do
    test "reads the meta tag of Phoenix's layouts" do
      html = ~s(<head><meta charset="utf-8"><meta name="csrf-token" content="abc-1"></head>)
      assert HTTP.csrf_token(html) == "abc-1"
      assert HTTP.csrf_token(%{body: html}) == "abc-1"
    end

    test "reads a form's hidden input" do
      html = ~s(<form><input type="hidden" name="_csrf_token" value="abc-2"></form>)
      assert HTTP.csrf_token(html) == "abc-2"
    end

    test "is nil on a page with neither" do
      assert HTTP.csrf_token("<p>nothing here</p>") == nil
    end
  end

  test "returns responses with error statuses" do
    assert {:ok, %{status: 500}} = HTTP.get(url("/api/fail"))
  end

  test "returns an error when nothing is listening" do
    assert {:error, %Mint.TransportError{reason: :econnrefused}} =
             HTTP.get("http://127.0.0.1:1/api/hello")
  end

  test "raises on URLs that are not HTTP" do
    assert_raise ArgumentError, ~r"expected an http:// or https:// URL", fn ->
      HTTP.get("ws://127.0.0.1/api/hello")
    end
  end

  describe "connections" do
    test "are kept open between requests" do
      {:ok, %{body: first}} = HTTP.get(url("/api/port"))
      {:ok, %{body: second}} = HTTP.get(url("/api/port"))

      assert first == second
    end

    test "are opened again after the server closes them" do
      {:ok, %{body: first}} = HTTP.get(url("/api/port"))
      {:ok, %{body: "bye"}} = HTTP.get(url("/api/close"))
      {:ok, %{body: second}} = HTTP.get(url("/api/port"))

      assert first != second
    end

    test "send requests that are safe to repeat again when the old one is gone" do
      {:ok, %{body: first}} = HTTP.get(url("/api/port"))

      # Closes the kept connection behind the client's back, like a server
      # timing it out between requests.
      for {{HTTP, _scheme, _host, _port, _opts}, conn} <- Process.get() do
        :ok = :gen_tcp.close(Mint.HTTP.get_socket(conn))
      end

      {:ok, %{body: second}} = HTTP.get(url("/api/port"))
      assert first != second
    end
  end

  test "records requests, and responses with error statuses as errors, inside a run" do
    result = Stampede.run(Calling, vus: 1, duration: 1_000, graceful_stop: 10_000)

    # Every iteration sends two requests as "http.request", one of them failing,
    # and a third one as "hello". The last iteration may be cut short.
    assert %{type: :timing, count: requests} = result.metrics["http.request"]
    assert %{type: :counter, count: errors} = result.metrics["http.request.errors"]
    assert_in_delta requests, 2 * errors, 1
    assert_in_delta result.metrics["hello"].count, errors, 1
  end
end
