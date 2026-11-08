defmodule Load.ChatDb do
  @moduledoc """
  People in a chat app backed by Postgres, about 100 to a room. Each one joins
  a room, which reads the latest 50 messages, then every `PAUSE` seconds either
  sends a message, which is written to Postgres before the reply comes back, or
  scrolls up for the 50 before the oldest it has, one time in five.

  `USERS` and `ROOMS` must match how the database was seeded.
  """

  use Stampede.Scenario

  @per_room 100

  @impl true
  def options do
    Load.options([
      {"channel.join", p95: 1_000},
      {"chat.send", p95: 1_000},
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

    {:ok, socket} =
      Stampede.Channels.connect(Load.url("ws", "/socket"),
        params: %{user_id: user_id},
        transport_opts: Load.transport_opts(vu),
        connect_timeout: 30_000,
        # A VU hears every message in its room but only reads its own replies.
        keep: fn _payload -> false end
      )

    topic = "room:#{room}"
    {:ok, %{"messages" => messages}} = Stampede.Channels.join(socket, topic, %{}, timeout: 30_000)
    chat(socket, topic, oldest(messages, nil), 0)
  end

  defp chat(socket, topic, oldest, count) do
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
        body = "Hello from a load test, message #{count}"

        {:ok, _reply} =
          Stampede.Channels.push(socket, topic, "new_msg", %{body: body},
            metric: "chat.send",
            timeout: 30_000
          )

        oldest
      end

    chat(socket, topic, oldest, count + 1)
  end

  defp oldest([], previous), do: previous
  defp oldest(messages, _previous), do: messages |> List.last() |> Map.fetch!("id")

  defp env(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end
end
