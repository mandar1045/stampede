# Phoenix Presence

Presence is often the first part of a channel to slow down as it grows.
Every join and every leave is broadcast to everyone in the topic, so when a
thousand people join a room, the server sends about a million messages.

Here is a room channel that tracks everyone who joins, straight from the
`Phoenix.Presence` docs:

```elixir
defmodule MyAppWeb.RoomChannel do
  use MyAppWeb, :channel

  alias MyAppWeb.Presence

  @impl true
  def join("room:" <> _id, %{"name" => name}, socket) do
    send(self(), :after_join)
    {:ok, assign(socket, :name, name)}
  end

  @impl true
  def handle_info(:after_join, socket) do
    {:ok, _ref} = Presence.track(socket, socket.assigns.name, %{})
    push(socket, "presence_state", Presence.list(socket))
    {:noreply, socket}
  end
end
```

## The scenario

What people notice is how long it takes before others see them. A good
stand-in is how long a user takes to see their own join, since it reaches
them along with everyone else in the room:

```elixir
defmodule MyApp.Load.Room do
  use Stampede.Scenario

  @impl true
  def options do
    [
      stages: [{[minute: 1], 1_000}, {[minute: 2], 1_000}, {[second: 10], 0}],
      thresholds: [{"presence.seen", p95: 500}, {"iteration.errors", count: 0}]
    ]
  end

  @impl true
  def run(vu) do
    name = "user-#{vu.id}-#{vu.iteration}"
    {:ok, socket} = Stampede.Channels.connect("ws://localhost:4000/socket")

    Stampede.measure("presence.seen", fn ->
      {:ok, _reply} = Stampede.Channels.join(socket, "room:lobby", %{name: name})

      {:ok, _diff} =
        Stampede.Channels.await(socket, "room:lobby", "presence_diff",
          match: &Map.has_key?(&1["joins"], name)
        )
    end)

    {:ok, _state} = Stampede.Channels.await(socket, "room:lobby", "presence_state")

    # Stays in the room for a while, then leaves.
    Process.sleep(30_000)
  end
end
```

The name includes the iteration, so that a VU that joins again is a new
presence rather than a second connection of the same one.

## Reading the results

  * `presence.seen` is the time from asking to join to seeing yourself in the
    room. It grows with the number of people in the room, since every diff
    goes to all of them.
  * `channel.messages` counts the presence diffs every socket received. With
    `n` users in a room, expect close to `n` messages for each join.
  * `channel.messages.dropped` grows too, and that's expected here. Each
    socket keeps the last 1,000 messages it hasn't read, and this scenario
    only reads its own join.

To see how presence scales, run the same scenario with more VUs, or with
`rate:` to keep users arriving at a steady pace while others leave.
