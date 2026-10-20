defmodule Stampede.Channels.Serializer do
  @moduledoc """
  Turns messages into WebSocket frames and back.

  `Stampede.Channels.connect/2` picks `Stampede.Channels.Serializer.V2` or
  `Stampede.Channels.Serializer.V1` from its `:vsn`. A server that extends
  the protocol with frames of its own can be given a serializer with the
  `:serializer` option, usually one that handles those frames and leaves the
  rest to a built-in one:

      defmodule MyApp.Load.Serializer do
        @behaviour Stampede.Channels.Serializer

        alias Stampede.Channels.{Message, Serializer}

        @impl true
        def encode(message), do: Serializer.V2.encode(message)

        @impl true
        def decode({:binary, <<9, size, topic::binary-size(size), data::binary>>}) do
          {:ok, %Message{topic: topic, event: "snapshot", payload: {:binary, data}}}
        end

        def decode(frame), do: Serializer.V2.decode(frame)
      end
  """

  alias Stampede.Channels.Message

  @type frame :: {:text, binary()} | {:binary, binary()}

  @doc """
  Encodes a message to send to the server.

  It may raise, for example when the payload cannot be encoded, and the
  exception is then raised where the message was pushed.
  """
  @callback encode(Message.t()) :: frame()

  @doc """
  Decodes a frame sent by the server, or returns `:error` to ignore it.
  """
  @callback decode(frame()) :: {:ok, Message.t()} | :error
end

defmodule Stampede.Channels.Serializer.V2 do
  @moduledoc """
  The `"2.0.0"` serializer, used by default.

  Messages are JSON arrays, and `{:binary, data}` payloads are sent and
  received as binary frames, as `Phoenix.Socket.V2.JSONSerializer` does.
  """

  @behaviour Stampede.Channels.Serializer

  alias Stampede.Channels.Message

  @push 0
  @reply 1
  @broadcast 2

  @impl true
  def encode(%Message{payload: {:binary, data}} = message) when is_binary(data) do
    join_ref = message.join_ref || ""
    ref = message.ref || ""

    header = <<
      @push,
      size!(join_ref, :join_ref),
      size!(ref, :ref),
      size!(message.topic, :topic),
      size!(message.event, :event)
    >>

    {:binary, header <> join_ref <> ref <> message.topic <> message.event <> data}
  end

  def encode(%Message{} = message) do
    {:text,
     JSON.encode!([message.join_ref, message.ref, message.topic, message.event, message.payload])}
  end

  @impl true
  def decode({:text, text}) do
    case JSON.decode(text) do
      {:ok, [join_ref, ref, topic, event, payload]} ->
        {:ok,
         %Message{join_ref: join_ref, ref: ref, topic: topic, event: event, payload: payload}}

      _other ->
        :error
    end
  end

  def decode(
        {:binary,
         <<@push, join_ref_size, topic_size, event_size, join_ref::binary-size(join_ref_size),
           topic::binary-size(topic_size), event::binary-size(event_size), data::binary>>}
      ) do
    {:ok,
     %Message{join_ref: present(join_ref), topic: topic, event: event, payload: {:binary, data}}}
  end

  def decode(
        {:binary,
         <<@reply, join_ref_size, ref_size, topic_size, status_size,
           join_ref::binary-size(join_ref_size), ref::binary-size(ref_size),
           topic::binary-size(topic_size), status::binary-size(status_size), data::binary>>}
      ) do
    {:ok,
     %Message{
       join_ref: present(join_ref),
       ref: ref,
       topic: topic,
       event: "phx_reply",
       payload: %{"status" => status, "response" => {:binary, data}}
     }}
  end

  def decode(
        {:binary,
         <<@broadcast, topic_size, event_size, topic::binary-size(topic_size),
           event::binary-size(event_size), data::binary>>}
      ) do
    {:ok, %Message{topic: topic, event: event, payload: {:binary, data}}}
  end

  def decode(_frame), do: :error

  defp size!(field, name) do
    case byte_size(field) do
      size when size <= 255 ->
        size

      size ->
        raise ArgumentError,
              "expected the #{name} of a binary message to be at most 255 bytes, got: #{size}"
    end
  end

  defp present(""), do: nil
  defp present(field), do: field
end

defmodule Stampede.Channels.Serializer.V1 do
  @moduledoc """
  The `"1.0.0"` serializer, where messages are JSON objects.

  It has no binary payloads.
  """

  @behaviour Stampede.Channels.Serializer

  alias Stampede.Channels.Message

  @impl true
  def encode(%Message{payload: {:binary, _data}}) do
    raise ArgumentError, ~s(binary payloads need the 2.0.0 serializer, connect with vsn: "2.0.0")
  end

  def encode(%Message{} = message) do
    {:text,
     JSON.encode!(%{
       "join_ref" => message.join_ref,
       "ref" => message.ref,
       "topic" => message.topic,
       "event" => message.event,
       "payload" => message.payload
     })}
  end

  @impl true
  def decode({:text, text}) do
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

  def decode(_frame), do: :error
end
