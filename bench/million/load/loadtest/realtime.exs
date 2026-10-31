defmodule Load.Realtime do
  @moduledoc """
  People in group chats on Supabase Realtime: 100 users in each channel, the
  shape of Supabase's own large-scale benchmark. Each one connects, joins and
  stays, sending a broadcast every `PAUSE` seconds that everyone in the channel
  receives, and times it coming back. At the default of 30 to 60 seconds, each
  channel gets about 2 messages a second, as in their benchmark.
  """

  use Stampede.Scenario

  @per_channel 100

  @impl true
  def options do
    Load.options([
      {"channel.join", p95: 1_000},
      {"broadcast.roundtrip", p95: 1_000},
      {"iteration.errors", count: 0}
    ])
  end

  @impl true
  def run(vu) do
    {:ok, socket} = RealtimeLoad.connect(vu, &(&1["payload"]["from"] == vu.id))
    channel = "load-#{div(vu.id, @per_channel)}"
    {:ok, _reply} = RealtimeLoad.join(socket, channel, %{broadcast: %{self: true, ack: true}})
    talk(socket, "realtime:" <> channel, vu, 0)
  end

  defp talk(socket, topic, vu, count) do
    Load.pause()
    id = "#{vu.id}-#{count}"
    payload = %{id: id, from: vu.id, text: "Hello everyone"}
    message = %{type: "broadcast", event: "shout", payload: payload}

    Stampede.measure("broadcast.roundtrip", fn ->
      {:ok, _ack} =
        Stampede.Channels.push(socket, topic, "broadcast", message,
          metric: "broadcast.ack",
          timeout: 30_000
        )

      {:ok, _message} =
        Stampede.Channels.await(socket, topic, "broadcast",
          match: &(&1["payload"]["id"] == id),
          timeout: 30_000
        )
    end)

    talk(socket, topic, vu, count + 1)
  end
end
