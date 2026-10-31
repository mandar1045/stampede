defmodule RealtimeLoad do
  @moduledoc """
  Connects to Supabase Realtime the way `realtime-js` does: with an API key, a
  heartbeat every 25 seconds, and the binary broadcasts of protocol 2.0.0.

  `SERVER` has to start with the tenant's name, since Realtime reads it from
  the host, such as `realtime-dev.bench:4000`.
  """

  # `keep` picks the VU's own messages out of everything it hears.
  def connect(vu, keep) do
    Stampede.Channels.connect(Load.url("ws", "/socket"),
      params: %{apikey: token()},
      serializer: RealtimeLoad.Serializer,
      heartbeat_interval: 25_000,
      connect_timeout: 30_000,
      keep: keep,
      transport_opts: Load.transport_opts(vu)
    )
  end

  def join(socket, channel, config) do
    Stampede.Channels.join(
      socket,
      "realtime:" <> channel,
      %{config: config, access_token: token()}, timeout: 30_000)
  end

  # A JWT signed with the tenant's secret, like the one an anonymous user has.
  def token do
    header = encode(%{alg: "HS256", typ: "JWT"})
    claims = encode(%{role: "anon", iss: "stampede", exp: System.os_time(:second) + 21_600})

    signature =
      :crypto.mac(:hmac, :sha256, System.fetch_env!("JWT_SECRET"), header <> "." <> claims)

    header <> "." <> claims <> "." <> Base.url_encode64(signature, padding: false)
  end

  defp encode(map), do: map |> JSON.encode!() |> Base.url_encode64(padding: false)
end

defmodule RealtimeLoad.Serializer do
  @moduledoc """
  Adds Realtime's binary broadcasts to the built-in serializer, as described
  in the Supabase Realtime guide.
  """

  @behaviour Stampede.Channels.Serializer

  alias Stampede.Channels.Message
  alias Stampede.Channels.Serializer.V2

  @user_broadcast_push 3
  @user_broadcast 4

  @impl true
  def encode(
        %Message{event: "broadcast", payload: %{type: "broadcast", event: event} = payload} =
          message
      ) do
    data = JSON.encode!(Map.get(payload, :payload, %{}))
    join_ref = message.join_ref || ""
    ref = message.ref || ""

    header =
      <<@user_broadcast_push, byte_size(join_ref), byte_size(ref), byte_size(message.topic),
        byte_size(event), 0, 1>>

    {:binary, header <> join_ref <> ref <> message.topic <> event <> data}
  end

  def encode(message), do: V2.encode(message)

  @impl true
  def decode(
        {:binary,
         <<@user_broadcast, topic_size, event_size, metadata_size, 1,
           topic::binary-size(topic_size), event::binary-size(event_size),
           _metadata::binary-size(metadata_size), data::binary>>}
      ) do
    payload = %{"type" => "broadcast", "event" => event, "payload" => JSON.decode!(data)}
    {:ok, %Message{topic: topic, event: "broadcast", payload: payload}}
  end

  def decode(frame), do: V2.decode(frame)
end
