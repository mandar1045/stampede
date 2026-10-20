defmodule Stampede.Channels.SerializerTest do
  use ExUnit.Case, async: true

  alias Stampede.Channels.{Message, Serializer}

  @message %Message{
    join_ref: "1",
    ref: "2",
    topic: "room:lobby",
    event: "ping",
    payload: %{"n" => 1}
  }

  test "encodes and decodes 2.0.0 messages" do
    assert Serializer.encode(@message, "2.0.0") == ~s(["1","2","room:lobby","ping",{"n":1}])

    assert Serializer.decode(~s([null,null,"room:lobby","shout",{"body":"hi"}]), "2.0.0") ==
             {:ok, %Message{topic: "room:lobby", event: "shout", payload: %{"body" => "hi"}}}
  end

  test "encodes and decodes 1.0.0 messages" do
    assert @message |> Serializer.encode("1.0.0") |> JSON.decode!() == %{
             "join_ref" => "1",
             "ref" => "2",
             "topic" => "room:lobby",
             "event" => "ping",
             "payload" => %{"n" => 1}
           }

    assert Serializer.decode(
             ~s({"topic":"room:lobby","event":"phx_reply","ref":"2","payload":{}}),
             "1.0.0"
           ) ==
             {:ok, %Message{ref: "2", topic: "room:lobby", event: "phx_reply", payload: %{}}}
  end

  test "rejects messages it cannot decode" do
    assert Serializer.decode("not json", "2.0.0") == :error
    assert Serializer.decode(~s(["1","2"]), "2.0.0") == :error
    assert Serializer.decode(~s({"topic":"room:lobby"}), "1.0.0") == :error
  end
end
