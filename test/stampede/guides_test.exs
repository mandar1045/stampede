defmodule Stampede.GuidesTest do
  # Runs the scenarios of the guides, with the test server's URLs and shorter
  # waits, to show that they work as written.
  use ExUnit.Case, async: true

  defmodule Room do
    use Stampede.Scenario

    @impl true
    def run(vu) do
      name = "user-#{vu.id}-#{vu.iteration}"
      {:ok, socket} = Stampede.Channels.connect(Stampede.TestEndpoint.socket_url())

      Stampede.measure("presence.seen", fn ->
        {:ok, _reply} = Stampede.Channels.join(socket, "presence:lobby", %{name: name})

        {:ok, _diff} =
          Stampede.Channels.await(socket, "presence:lobby", "presence_diff",
            match: &Map.has_key?(&1["joins"], name)
          )
      end)

      {:ok, _state} = Stampede.Channels.await(socket, "presence:lobby", "presence_state")
      Process.sleep(100)
    end
  end

  test "Phoenix Presence" do
    result = Stampede.run(Room, vus: 5, duration: 1_000)

    assert result.errors == []
    assert result.metrics["presence.seen"].count > 5
    assert result.metrics["channel.messages"].count > result.metrics["presence.seen"].count
  end
end
