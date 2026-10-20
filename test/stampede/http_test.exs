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
    result = Stampede.run(Calling, vus: 1, duration: 1_000)

    # Every iteration sends two requests as "http.request", one of them failing,
    # and a third one as "hello". The last iteration may be cut short.
    assert %{type: :timing, count: requests} = result.metrics["http.request"]
    assert %{type: :counter, count: errors} = result.metrics["http.request.errors"]
    assert_in_delta requests, 2 * errors, 1
    assert_in_delta result.metrics["hello"].count, errors, 1
  end
end
