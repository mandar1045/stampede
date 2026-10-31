defmodule Stampede.GuidesTest do
  # Runs the scenarios of the guides, with the test server's URLs and shorter
  # waits, to show that they work as written.
  use ExUnit.Case, async: true

  defmodule Conversation do
    use Stampede.Scenario

    @impl true
    def setup(_opts), do: [[%{role: "user", content: "Tell me about Lisbon."}]]

    @impl true
    def run(vu) do
      url = Stampede.TestEndpoint.page_url("/v1")
      first = Enum.random(vu.data)
      {:ok, reply} = Stampede.LLM.chat(url, model: "mock", messages: first, max_tokens: 2)

      Process.sleep(10)

      next =
        first ++
          [%{role: "assistant", content: reply.content}, %{role: "user", content: "Where?"}]

      {:ok, _reply} = Stampede.LLM.chat(url, model: "mock", messages: next, max_tokens: 2)
    end
  end

  test "AI chat APIs" do
    result = Stampede.run(Conversation, vus: 2, duration: 1_500, graceful_stop: 10_000)

    assert result.errors == []
    assert result.metrics["llm.ttft"].count >= 2
  end

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
    result = Stampede.run(Room, vus: 5, duration: 1_000, graceful_stop: 10_000)

    assert result.errors == []
    assert result.metrics["presence.seen"].count >= 5
    assert result.metrics["channel.messages"].count > result.metrics["presence.seen"].count
  end
end
