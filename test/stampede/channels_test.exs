defmodule Stampede.ChannelsTest do
  use ExUnit.Case, async: true

  alias Stampede.Channels

  setup do
    %{url: Stampede.TestEndpoint.socket_url()}
  end

  defp join_lobby(%{url: url}) do
    {:ok, socket} = Channels.connect(url)
    {:ok, _reply} = Channels.join(socket, "room:lobby")
    %{socket: socket}
  end

  describe "connect/2" do
    test "connects to a Phoenix socket", %{url: url} do
      assert {:ok, socket} = Channels.connect(url)
      assert Process.alive?(socket)
    end

    test "returns an error when the socket refuses the connection", %{url: url} do
      assert {:error, %Mint.WebSocket.UpgradeFailureError{status_code: 403}} =
               Channels.connect(url, params: %{token: "invalid"})
    end

    test "returns an error when nothing is listening" do
      assert {:error, %Mint.TransportError{reason: :econnrefused}} =
               Channels.connect("ws://127.0.0.1:1/socket")
    end

    test "raises on URLs that are not WebSockets" do
      assert_raise ArgumentError, ~r"expected a ws:// or wss:// URL", fn ->
        Channels.connect("http://localhost:4000/socket")
      end
    end

    test "raises on serializer versions it does not support", %{url: url} do
      assert_raise ArgumentError, ~r/expected :vsn to be one of/, fn ->
        Channels.connect(url, vsn: "3.0.0")
      end
    end

    test "supports the 1.0.0 serializer", %{url: url} do
      {:ok, socket} = Channels.connect(url, vsn: "1.0.0")

      assert {:ok, %{"joined" => true}} = Channels.join(socket, "room:lobby")

      assert {:ok, %{"pong" => %{"n" => 1}}} =
               Channels.push(socket, "room:lobby", "ping", %{n: 1})
    end

    # The heartbeat timer is driven by hand, so the tests do not depend on how
    # fast the server answers.
    test "stays open while heartbeats are answered", %{url: url} do
      {:ok, socket} = Channels.connect(url, heartbeat_interval: nil)

      send(socket, :heartbeat)
      assert {:ok, _reply} = Channels.join(socket, "room:lobby")
      send(socket, :heartbeat)
      assert {:ok, _reply} = Channels.push(socket, "room:lobby", "ping")
    end

    test "closes when a heartbeat is still unanswered at the next one", %{url: url} do
      {:ok, socket} = Channels.connect(url, heartbeat_interval: nil)
      ref = Process.monitor(socket)

      send(socket, :heartbeat)
      send(socket, :heartbeat)

      assert_receive {:DOWN, ^ref, :process, ^socket, :normal}
    end
  end

  describe "join/4" do
    test "returns the channel's reply", %{url: url} do
      {:ok, socket} = Channels.connect(url)

      assert {:ok, %{"joined" => true, "echo" => %{"name" => "jo"}}} =
               Channels.join(socket, "room:lobby", %{name: "jo"})
    end

    test "returns the reply of a refused join", %{url: url} do
      {:ok, socket} = Channels.connect(url)

      assert {:error, %{"reason" => "unauthorized"}} = Channels.join(socket, "room:private")
    end
  end

  describe "push/5" do
    setup :join_lobby

    test "returns the channel's reply", %{socket: socket} do
      assert {:ok, %{"pong" => %{"n" => 1}}} =
               Channels.push(socket, "room:lobby", "ping", %{n: 1})
    end

    test "returns error replies", %{socket: socket} do
      assert {:error, %{"reason" => "failed"}} = Channels.push(socket, "room:lobby", "fail")
    end

    test "times out when the channel does not reply", %{socket: socket} do
      assert {:error, :timeout} = Channels.push(socket, "room:lobby", "silent", %{}, timeout: 50)
    end

    @tag capture_log: true
    test "fails pushes the channel crashes on", %{socket: socket} do
      assert {:error, :channel_crashed} = Channels.push(socket, "room:lobby", "crash")
    end

    @tag capture_log: true
    test "returns an error for topics that were not joined", %{socket: socket} do
      assert {:error, %{"reason" => "unmatched topic"}} =
               Channels.push(socket, "room:other", "ping")
    end
  end

  describe "await/4" do
    setup :join_lobby

    test "returns broadcasts", %{socket: socket} do
      :ok = Channels.cast(socket, "room:lobby", "shout", %{body: "hi"})

      assert {:ok, %{"body" => "hi"}} = Channels.await(socket, "room:lobby", "shout")
    end

    test "returns messages that arrived before it was called, oldest first", %{socket: socket} do
      :ok = Channels.cast(socket, "room:lobby", "shout", %{n: 1})
      :ok = Channels.cast(socket, "room:lobby", "shout", %{n: 2})
      {:ok, _reply} = Channels.push(socket, "room:lobby", "ping")

      assert {:ok, %{"n" => 1}} = Channels.await(socket, "room:lobby", "shout")
      assert {:ok, %{"n" => 2}} = Channels.await(socket, "room:lobby", "shout")
    end

    test "times out when nothing arrives", %{socket: socket} do
      assert {:error, :timeout} = Channels.await(socket, "room:lobby", "shout", 50)
    end
  end

  describe "leave/3" do
    setup :join_lobby

    @tag capture_log: true
    test "leaves the channel", %{socket: socket} do
      assert :ok = Channels.leave(socket, "room:lobby")

      assert {:error, %{"reason" => "unmatched topic"}} =
               Channels.push(socket, "room:lobby", "ping")
    end

    test "joins again after leaving", %{socket: socket} do
      assert :ok = Channels.leave(socket, "room:lobby")
      assert {:ok, _reply} = Channels.join(socket, "room:lobby")
      assert {:ok, %{"pong" => %{}}} = Channels.push(socket, "room:lobby", "ping")
    end
  end

  test "close/1 closes the connection", %{url: url} do
    {:ok, socket} = Channels.connect(url)

    assert :ok = Channels.close(socket)
    refute Process.alive?(socket)
    assert {:error, :closed} = Channels.join(socket, "room:lobby")
  end
end
