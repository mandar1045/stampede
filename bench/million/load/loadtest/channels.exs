defmodule Load.Channels do
  @moduledoc """
  People in a chat room: each one connects, joins `room:lobby` and stays,
  sending a message every `PAUSE` seconds.
  """

  use Stampede.Scenario

  @impl true
  def options do
    Load.options([
      {"channel.join", p95: 1_000},
      {"channel.push", p95: 1_000},
      {"iteration.errors", count: 0}
    ])
  end

  @impl true
  def run(vu) do
    {:ok, socket} =
      Stampede.Channels.connect(Load.url("ws", "/socket"),
        transport_opts: Load.transport_opts(vu),
        connect_timeout: 30_000
      )

    {:ok, _reply} = Stampede.Channels.join(socket, "room:lobby", %{}, timeout: 30_000)
    chat(socket)
  end

  defp chat(socket) do
    Load.pause()
    {:ok, _reply} = Stampede.Channels.push(socket, "room:lobby", "ping", %{"body" => "hi"})
    chat(socket)
  end
end
