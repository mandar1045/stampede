defmodule Load.Chat do
  @moduledoc """
  People chatting with an AI model: each one asks a question, reads the answer
  as it streams in, thinks for `PAUSE` seconds and asks another. `SERVER` is
  the model server's address, and `MODEL` the model to ask.
  """

  use Stampede.Scenario

  @questions [
    "Why is the sky blue?",
    "What's a good way to learn to cook?",
    "How do bridges stay up?",
    "Explain what a database index does.",
    "Why do cats purr?",
    "What should I see on a first trip to Japan?",
    "How does a bicycle stay upright?",
    "What's the difference between weather and climate?"
  ]

  @impl true
  def options do
    Load.options([
      {"llm.ttft", p95: 2_000},
      {"llm.itl", p95: 200},
      {"iteration.errors", count: 0}
    ])
  end

  @impl true
  def run(_vu) do
    {:ok, reply} =
      Stampede.LLM.chat(Load.url("http", "/v1"),
        model: System.get_env("MODEL", "qwen2.5:0.5b"),
        messages: [%{role: "user", content: question()}],
        max_tokens: 128
      )

    Stampede.check("finished", reply.finish_reason in ["stop", "length"])
    Load.pause()
  end

  # Model servers reuse the work of a prompt they've seen before. Real people
  # don't all send the same words, so every question starts differently.
  defp question, do: "Ticket #{:rand.uniform(1_000_000)}: #{Enum.random(@questions)}"
end
