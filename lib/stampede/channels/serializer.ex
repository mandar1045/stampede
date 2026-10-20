defmodule Stampede.Channels.Serializer do
  @moduledoc false

  alias Stampede.Channels.Message

  def encode(%Message{} = message, "2.0.0") do
    JSON.encode!([message.join_ref, message.ref, message.topic, message.event, message.payload])
  end

  def encode(%Message{} = message, "1.0.0") do
    JSON.encode!(%{
      "join_ref" => message.join_ref,
      "ref" => message.ref,
      "topic" => message.topic,
      "event" => message.event,
      "payload" => message.payload
    })
  end

  def decode(text, "2.0.0") do
    case JSON.decode(text) do
      {:ok, [join_ref, ref, topic, event, payload]} ->
        {:ok,
         %Message{join_ref: join_ref, ref: ref, topic: topic, event: event, payload: payload}}

      _other ->
        :error
    end
  end

  def decode(text, "1.0.0") do
    case JSON.decode(text) do
      {:ok, %{"topic" => topic, "event" => event} = message} ->
        {:ok,
         %Message{
           join_ref: message["join_ref"],
           ref: message["ref"],
           topic: topic,
           event: event,
           payload: message["payload"]
         }}

      _other ->
        :error
    end
  end
end
