# Case study: Supabase Realtime

[Supabase Realtime](https://github.com/supabase/realtime) is an Elixir server
that sends database changes, broadcasts and presence to clients over Phoenix
Channels. It extends the Channels protocol with binary broadcasts of its
own, which makes it a good example of load testing a real Phoenix system
that goes beyond the defaults.

I ran these load tests against a local Realtime, started from a checkout
of its repository, with a tenant of their own. Realtime limits how many
users, joins and events each tenant may have, to protect production
servers, so I raised that tenant's limits first.

## Speaking Realtime's protocol

Realtime's clients connect with an API key, and join each channel with an
access token, a JWT signed with the tenant's secret. A few helpers keep
that out of the scenarios:

```elixir
defmodule RealtimeLoad do
  def connect do
    url = "ws://#{tenant()}.localhost:4000/socket"
    Stampede.Channels.connect(url, params: %{apikey: token()}, serializer: RealtimeLoad.Serializer)
  end

  def join(socket, channel, config) do
    Stampede.Channels.join(socket, "realtime:" <> channel, %{config: config, access_token: token()})
  end

  # A JWT signed with the tenant's secret, like the one an anonymous user has.
  def token do
    header = encode(%{alg: "HS256", typ: "JWT"})
    claims = encode(%{role: "anon", iss: "stampede", exp: System.os_time(:second) + 3_600})
    signature = :crypto.mac(:hmac, :sha256, System.get_env("JWT_SECRET", "dev"), header <> "." <> claims)
    header <> "." <> claims <> "." <> Base.url_encode64(signature, padding: false)
  end

  defp tenant, do: System.get_env("TENANT", "realtime-dev")
  defp encode(map), do: map |> JSON.encode!() |> Base.url_encode64(padding: false)
end
```

With Phoenix's `"2.0.0"` protocol, Realtime sends and receives broadcasts as
binary frames of its own, as `realtime-js` does. A
`Stampede.Channels.Serializer` adds them to the built-in serializer, and
leaves every other message to it:

```elixir
defmodule RealtimeLoad.Serializer do
  @behaviour Stampede.Channels.Serializer

  alias Stampede.Channels.Message
  alias Stampede.Channels.Serializer.V2

  @user_broadcast_push 3
  @user_broadcast 4

  # Broadcasts go out as user broadcast pushes, with a JSON payload.
  @impl true
  def encode(%Message{event: "broadcast", payload: %{type: "broadcast", event: event} = payload} = message) do
    data = JSON.encode!(Map.get(payload, :payload, %{}))
    join_ref = message.join_ref || ""
    ref = message.ref || ""

    header =
      <<@user_broadcast_push, byte_size(join_ref), byte_size(ref), byte_size(message.topic),
        byte_size(event), 0, 1>>

    {:binary, header <> join_ref <> ref <> message.topic <> event <> data}
  end

  def encode(message), do: V2.encode(message)

  # They come back as user broadcasts, read into the same payloads as with
  # the JSON protocol.
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
```

## Broadcast

Every user joins the same channel and sends a broadcast a second, with
`self: true` so that it comes back to them, and times the round trip:

```elixir
defmodule RealtimeLoad.Broadcast do
  use Stampede.Scenario

  @impl true
  def options do
    [
      stages: [{[second: 10], 50}, {[second: 30], 50}, {[second: 5], 0}],
      graceful_stop: [second: 15],
      thresholds: [{"broadcast.roundtrip", p95: 100}, {"iteration.errors", count: 0}]
    ]
  end

  @impl true
  def run(vu) do
    {:ok, socket} = RealtimeLoad.connect()
    {:ok, _reply} = RealtimeLoad.join(socket, "load", %{broadcast: %{self: true, ack: true}})

    for i <- 1..10 do
      id = "#{vu.id}-#{vu.iteration}-#{i}"
      message = %{type: "broadcast", event: "shout", payload: %{id: id}}

      Stampede.measure("broadcast.roundtrip", fn ->
        {:ok, _ack} =
          Stampede.Channels.push(socket, "realtime:load", "broadcast", message, metric: "broadcast.ack")

        {:ok, _message} =
          Stampede.Channels.await(socket, "realtime:load", "broadcast",
            match: &(&1["payload"]["id"] == id)
          )
      end)

      Process.sleep(1_000)
    end
  end
end
```

Every broadcast goes to everyone in the channel, so with `n` users, the
server delivers `n` times as many messages as it receives.

## Presence and Postgres Changes

The two other scenarios follow the same shape:

  * **Presence.** Every user joins one channel, tracks itself, and times how
    long it takes to see its own join in a `presence_diff`, as in the
    [Phoenix Presence](presence.md) guide.
  * **Postgres Changes.** Every user subscribes to the inserts of its own
    rows, with a filter on a column. It then inserts a row a second with
    Postgrex, and times how long Realtime takes to deliver it. The scenario's
    `c:Stampede.Scenario.setup/1` creates the table and adds it to Realtime's
    publication.

## Results

Realtime 2.146.0, in dev mode, with the load test on the same laptop
(i5-13420H, 12 threads, 16 GB). At 400 users my laptop was 85% to 90% busy
running both, so read the larger runs as a floor for what Realtime can do,
not its limit. No run had errors, dropped connections or failed
connections.

Broadcast, every user in one channel, for 30 seconds:

| Users | Protocol | Messages delivered/s | Round trip p50 | p95 | p99 |
|------:|---------:|---------------------:|---------------:|----:|----:|
| 50    | 2.0.0    | 2,400                | 2.8ms          | 11ms  | 33ms  |
| 200   | 2.0.0    | 36,600               | 23ms           | 140ms | 171ms |
| 400   | 2.0.0    | 128,400              | 100ms          | 306ms | 680ms |
| 200   | 1.0.0    | 36,300               | 24ms           | 132ms | 189ms |
| 400   | 1.0.0    | 133,500              | 88ms           | 282ms | 456ms |

Presence, ramping up to 200 users: users saw their own join 2.5ms after
tracking themselves at p50, 6.7ms at p95 and 10.4ms at p99, over 297,000
messages.

Postgres Changes, one insert a second per user for 30 seconds, with a
`poll_interval_ms` of 100:

| Users | Changes | p50   | p95   | p99   |
|------:|--------:|------:|------:|------:|
| 1     | 30      | 33ms  | 504ms | 514ms |
| 10    | 300     | 41ms  | 504ms | 525ms |
| 25    | 750     | 68ms  | 525ms | 546ms |
| 50    | 1,250   | 152ms | 568ms | 603ms |
| 100   | 2,000   | 447ms | 918ms | 1.04s |

## What the numbers showed

  * Messages delivered grew with the square of the users, as they should
    when everyone hears everyone, and the binary protocol performed like
    JSON. At 400 users the shared laptop was close to out of CPU, which
    likely accounts for much of the latency.
  * Postgres Changes had a p95 of about 500ms even with a single user, which
    surprised me at first. It's the poller backing off to five times
    `poll_interval_ms` while idle, so the first change after a quiet moment
    waits for the next poll. That's documented behavior, not a bug.
  * Postgres Changes latency grew with the number of subscribers, as
    Realtime's docs describe: every change is checked against the access of
    every subscriber.

Stampede took care of the connections, heartbeats and replies, so apart
from the serializer and a few helpers, the scenarios above are the whole
load test.
