defmodule Stampede.SSETest do
  use ExUnit.Case, async: true

  alias Stampede.SSE

  defp url(path), do: Stampede.TestEndpoint.page_url(path)

  test "reads events as they arrive, with when each one did" do
    assert {:ok, response} = SSE.get(url("/api/events?count=4&first=100&gap=50"))

    assert response.status == 200

    assert Enum.map(response.events, &{&1.event, &1.data, &1.id}) == [
             {"message", "token 1", "1"},
             {"message", "token 2", "2"},
             {"message", "token 3", "3"},
             {"message", "token 4", "4"}
           ]

    [first | _] = times = Enum.map(response.events, & &1.at)
    assert first >= 100
    assert times |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> b - a >= 40 end)
    assert response.body =~ "data: token 4\n\n"
  end

  test "reads streams the way the standard says, however they're split" do
    assert {:ok, %{events: events}} = SSE.get(url("/api/events/tricky"))

    assert Enum.map(events, &{&1.event, &1.data, &1.id}) == [
             {"greeting", "hello", nil},
             {"message", "first line\nsecond line", nil},
             {"message", "cr only", nil},
             {"message", "no space", "7"},
             {"message", "", "7"},
             {"message", "unterminated", "7"}
           ]
  end

  test "sends JSON, and asks for events unless told otherwise" do
    assert {:ok, %{status: 200, events: [_, _]}} =
             SSE.post(url("/api/events"), json: %{count: 2})

    assert {:ok, %{events: [_]}} =
             SSE.get(url("/api/events?count=1"), headers: [{"Accept", "*/*"}])
  end

  # The server logs dropping the broken stream's connection.
  @tag :capture_log
  test "returns errors, and responses that aren't streams" do
    assert {:ok, %{status: 429, events: [], body: body}} = SSE.get(url("/api/events/limited"))
    assert body =~ "rate limited"

    assert {:error, %Mint.TransportError{}} = SSE.get(url("/api/events/broken"))

    assert {:error, %Mint.TransportError{reason: :timeout}} =
             SSE.get(url("/api/events?count=2&first=500"), timeout: 100)
  end

  defmodule Streaming do
    use Stampede.Scenario

    @impl true
    def run(_vu) do
      {:ok, _response} =
        Stampede.SSE.get(Stampede.TestEndpoint.page_url("/api/events?count=3&first=50&gap=10"))
    end
  end

  defmodule Limited do
    use Stampede.Scenario

    @impl true
    def run(_vu), do: Stampede.SSE.get(Stampede.TestEndpoint.page_url("/api/events/limited"))
  end

  test "records the stream, the first event and the events in a run" do
    result = Stampede.run(Streaming, vus: 2, duration: 600, graceful_stop: 10_000)

    requests = result.metrics["sse.request"].count
    assert requests >= 2
    assert result.metrics["sse.events"].count == 3 * requests
    assert result.metrics["sse.first_event"].p50 >= 50
    assert result.metrics["sse.request"].p50 >= result.metrics["sse.first_event"].p50

    result = Stampede.run(Limited, vus: 1, duration: 200, graceful_stop: 10_000)
    assert result.metrics["sse.request.errors"].count == result.metrics["sse.request"].count
  end
end
