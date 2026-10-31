defmodule Stampede.WebSocketTest do
  use ExUnit.Case, async: true

  alias Stampede.TestEndpoint
  alias Stampede.WebSocket

  defp connect! do
    {:ok, ws} = WebSocket.connect(TestEndpoint.echo_url())
    assert {:ok, {:text, "welcome"}} = WebSocket.await(ws)
    ws
  end

  test "sends text and binary frames and awaits the answers" do
    ws = connect!()

    assert :ok = WebSocket.send(ws, "hello")
    assert {:ok, {:text, "hello"}} = WebSocket.await(ws)

    assert :ok = WebSocket.send(ws, {:binary, <<1, 2, 3>>})
    assert {:ok, {:binary, <<1, 2, 3>>}} = WebSocket.await(ws, 1_000)

    assert :ok = WebSocket.close(ws)
    refute Process.alive?(ws)
  end

  test "keeps frames that do not match for later" do
    ws = connect!()

    for text <- ["one", "two", "three"], do: :ok = WebSocket.send(ws, text)

    assert {:ok, {:text, "two"}} = WebSocket.await(ws, match: &(&1 == {:text, "two"}))
    assert {:ok, {:text, "three"}} = WebSocket.await(ws, match: fn {:text, "t" <> _} -> true end)
    assert {:ok, {:text, "one"}} = WebSocket.await(ws)
    assert {:error, :timeout} = WebSocket.await(ws, timeout: 50)
  end

  test "answers pings" do
    ws = connect!()

    :ok = WebSocket.send(ws, "ping me")
    assert {:ok, {:text, "pong hi"}} = WebSocket.await(ws)
  end

  test "keeps the frames received before the server closed the connection" do
    ws = connect!()

    :ok = WebSocket.send(ws, "close")
    assert {:ok, {:text, "closing"}} = WebSocket.await(ws)

    closed = {:closed, {:remote_close, 1000, "bye"}}
    assert {:error, ^closed} = WebSocket.await(ws)
    assert {:error, ^closed} = WebSocket.send(ws, "hello")
    assert :ok = WebSocket.close(ws)
  end

  test "returns errors for connections that fail" do
    url = String.replace(TestEndpoint.page_url("/api/hello"), "http", "ws")

    assert {:error, %Mint.WebSocket.UpgradeFailureError{status_code: 200}} =
             WebSocket.connect(url)

    assert {:error, %Mint.TransportError{}} = WebSocket.connect("ws://127.0.0.1:1/ws")

    assert_raise ArgumentError, ~r/ws:\/\/ or wss:\/\//, fn ->
      WebSocket.connect("http://localhost:4000/ws")
    end
  end

  test "records metrics and closes connections after each iteration" do
    result = Stampede.run(Stampede.Test.Echoing, vus: 2, duration: 1_000, graceful_stop: 10_000)

    assert result.errors == []
    iterations = result.metrics["iteration"].count
    assert iterations >= 2
    assert result.metrics["ws.connect"].count in iterations..(iterations + 2)
    assert result.metrics["ws.messages.sent"].count in iterations..(iterations + 2)
    assert result.metrics["ws.messages"].count >= 2 * iterations
    refute result.metrics["ws.disconnects"]
  end
end
