defmodule Load.ChatDb do
  @moduledoc """
  People in a chat app backed by Postgres, about 100 to a room. Each one joins
  a room, which reads the latest 50 messages, then every `PAUSE` seconds either
  sends a message, which is written to Postgres before the reply comes back, or
  scrolls up for the 50 before the oldest it has, one time in five.

  A message it sends is timed twice: `chat.send` until the reply, once it's
  written, and `chat.delivered` until it comes back to the sender in the room's
  broadcast, the way everyone else in the room gets it.

  `USERS` and `ROOMS` must match how the database was seeded, and `FANOUT` how
  the app was started, see `Chat.Fanout`.
  """

  use Stampede.Scenario

  @per_room 100

  @impl true
  def options do
    Load.options([
      {"channel.join", p95: 1_000},
      {"chat.send", p95: 1_000},
      {"chat.delivered", p95: 1_000},
      {"chat.history", p95: 1_000},
      {"iteration.errors", count: 0}
    ])
  end

  @impl true
  def run(vu) do
    users = env("USERS", 1_000_000)
    rooms = env("ROOMS", 10_000)
    user_id = :erlang.phash2(vu.id, users) + 1
    room = rem(div(vu.id, @per_room), rooms) + 1
    mine = "vu #{vu.id} "

    {:ok, socket} =
      Stampede.Channels.connect(Load.url("ws", "/socket"),
        params: %{user_id: user_id},
        transport_opts: Load.transport_opts(vu),
        connect_timeout: 30_000,
        # A VU hears every message in its room but only keeps its own.
        keep: fn payload -> Enum.any?(bodies(payload), &String.starts_with?(&1, mine)) end
      )

    topic = "room:#{room}"
    {:ok, %{"messages" => messages}} = Stampede.Channels.join(socket, topic, %{}, timeout: 30_000)
    chat(socket, topic, mine, oldest(messages, nil), 0)
  end

  defp chat(socket, topic, mine, oldest, count) do
    Load.pause()

    oldest =
      if rem(count, 5) == 4 and oldest do
        {:ok, %{"messages" => page}} =
          Stampede.Channels.push(socket, topic, "history", %{before: oldest},
            metric: "chat.history",
            timeout: 30_000
          )

        oldest(page, oldest)
      else
        body = mine <> "message #{count}: Hello from a load test"

        Stampede.measure("chat.delivered", fn ->
          {:ok, _reply} =
            Stampede.Channels.push(socket, topic, "new_msg", %{body: body},
              metric: "chat.send",
              timeout: 30_000
            )

          {:ok, _payload} =
            Stampede.Channels.await(socket, topic, delivered_event(),
              match: &(body in bodies(&1)),
              timeout: 30_000
            )
        end)

        oldest
      end

    chat(socket, topic, mine, oldest, count + 1)
  end

  # FANOUT=batch sends a room's messages together, as new_msgs.
  defp delivered_event do
    if System.get_env("FANOUT") == "batch", do: "new_msgs", else: "new_msg"
  end

  defp bodies(%{"messages" => messages}) when is_list(messages),
    do: Enum.map(messages, & &1["body"])

  defp bodies(%{"body" => body}), do: [body]
  defp bodies(_payload), do: []

  defp oldest([], previous), do: previous
  defp oldest(messages, _previous), do: messages |> List.last() |> Map.fetch!("id")

  defp env(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end
end
