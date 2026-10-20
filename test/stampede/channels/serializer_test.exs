defmodule Stampede.Channels.SerializerTest do
  use ExUnit.Case, async: true

  alias Stampede.Channels.Message
  alias Stampede.Channels.Serializer.{V1, V2}

  @message %Message{
    join_ref: "1",
    ref: "2",
    topic: "room:lobby",
    event: "ping",
    payload: %{"n" => 1}
  }

  describe "V2" do
    test "encodes and decodes JSON messages" do
      assert V2.encode(@message) == {:text, ~s(["1","2","room:lobby","ping",{"n":1}])}

      assert V2.decode({:text, ~s([null,null,"room:lobby","shout",{"body":"hi"}])}) ==
               {:ok, %Message{topic: "room:lobby", event: "shout", payload: %{"body" => "hi"}}}
    end

    test "encodes binary pushes" do
      assert V2.encode(%{@message | payload: {:binary, <<7, 8>>}}) ==
               {:binary, <<0, 1, 1, 10, 4, "1", "2", "room:lobby", "ping", 7, 8>>}
    end

    test "decodes binary pushes, replies and broadcasts" do
      assert V2.decode({:binary, <<0, 1, 10, 5, "1", "room:lobby", "bytes", 7, 8>>}) ==
               {:ok,
                %Message{
                  join_ref: "1",
                  topic: "room:lobby",
                  event: "bytes",
                  payload: {:binary, <<7, 8>>}
                }}

      assert V2.decode({:binary, <<1, 1, 1, 10, 2, "1", "2", "room:lobby", "ok", 7>>}) ==
               {:ok,
                %Message{
                  join_ref: "1",
                  ref: "2",
                  topic: "room:lobby",
                  event: "phx_reply",
                  payload: %{"status" => "ok", "response" => {:binary, <<7>>}}
                }}

      assert V2.decode({:binary, <<2, 10, 5, "room:lobby", "bytes", 7>>}) ==
               {:ok, %Message{topic: "room:lobby", event: "bytes", payload: {:binary, <<7>>}}}
    end

    test "raises on binary pushes with fields longer than 255 bytes" do
      assert_raise ArgumentError, ~r/the event of a binary message to be at most 255 bytes/, fn ->
        V2.encode(%{@message | event: String.duplicate("a", 256), payload: {:binary, ""}})
      end
    end

    test "rejects frames it cannot decode" do
      assert V2.decode({:text, "not json"}) == :error
      assert V2.decode({:text, ~s(["1","2"])}) == :error
      assert V2.decode({:binary, <<9, 1, 2>>}) == :error
      assert V2.decode({:binary, <<2, 10, 5, "room">>}) == :error
    end
  end

  describe "V1" do
    test "encodes and decodes JSON messages" do
      assert {:text, json} = V1.encode(@message)

      assert JSON.decode!(json) == %{
               "join_ref" => "1",
               "ref" => "2",
               "topic" => "room:lobby",
               "event" => "ping",
               "payload" => %{"n" => 1}
             }

      assert V1.decode(
               {:text, ~s({"topic":"room:lobby","event":"phx_reply","ref":"2","payload":{}})}
             ) ==
               {:ok, %Message{ref: "2", topic: "room:lobby", event: "phx_reply", payload: %{}}}
    end

    test "raises on binary payloads and ignores binary frames" do
      assert_raise ArgumentError, fn -> V1.encode(%{@message | payload: {:binary, ""}}) end
      assert V1.decode({:binary, <<2, 10, 5, "room:lobby", "bytes">>}) == :error
      assert V1.decode({:text, ~s({"topic":"room:lobby"})}) == :error
    end
  end
end
