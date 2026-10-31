# Load testing AI chat APIs

Everyone shipping a chatbot ends up asking the same thing: how many people
can talk to it at once before it feels slow? `Stampede.LLM` answers that for
any server with an OpenAI-style chat API, such as Ollama, vLLM, llama.cpp or
LM Studio. The server can be written in anything. Only the load test is in
Elixir, and it fits in one file. I've run it against Ollama so far, so if you
try it on something else, I'd like to hear how it went.

`Stampede.LLM` is new in 1.3, so it may still change a little.

## A first test

You don't need a project, just [Elixir](https://elixir-lang.org/install.html).
Save this as `chat.exs`, and change the URL and the model to yours:

```elixir
Mix.install([{:stampede, "~> 1.3"}])

defmodule Chat do
  use Stampede.Scenario

  @impl true
  def options do
    [
      find_limit: [step: 2, up_to: 40, hold: [second: 60]],
      thresholds: [
        {"llm.ttft", p95: 2_000},
        {"llm.itl", p95: 200},
        {"iteration.errors", count: 0}
      ]
    ]
  end

  @impl true
  def run(_vu) do
    {:ok, _reply} =
      Stampede.LLM.chat("http://localhost:11434/v1",
        model: "qwen2.5:0.5b",
        messages: [%{role: "user", content: "Why is the sky blue?"}],
        max_tokens: 128
      )

    # Reads the answer and thinks, as a person would.
    Process.sleep(Enum.random(5_000..10_000))
  end
end

result = Stampede.run(Chat, progress: true)
IO.puts(Stampede.Reporter.format(result))
```

Then run it:

```console
$ elixir chat.exs
```

It adds two users at a time, holds each step for a minute, and stops at the
first step that breaks a threshold. Here, that's the first token taking over
2 seconds, tokens more than 200ms apart, or any error. The summary tells you
the most users that held.

In a Mix project, `mix stampede.gen.scenario Chat --llm` writes a scenario to
start from, and everything else in Stampede works too: the live dashboard,
HTML reports, thresholds that fail your CI, and spreading the load over
machines.

## What it measures

`Stampede.LLM` measures these the same way as `vllm bench serve`, so numbers
from the two compare directly:

| Metric | What it is |
|---|---|
| `llm.ttft` | Time to first token: how long someone stares at nothing |
| `llm.itl` | Inter-token latency: every gap between tokens, how smooth the text feels |
| `llm.tpot` | Time per output token after the first, once per request |
| `llm.request` | The whole request, from start to end |
| `llm.tokens.output`, `llm.tokens.input` | Tokens generated and read. Their rate is tokens per second |
| `llm.request.errors` | Failures: a status of 400 or more, a broken stream, or no tokens at all |

## Use realistic prompts

Model servers reuse the work of a prompt they've just seen, so sending the
same question over and over makes them look much faster than they are. In my
first try, a repeated question got its first token in 12ms instead of about
a second. Real people don't all send the same words, so make prompts differ
at the start:

```elixir
question = Enum.random(["Why is the sky blue?", "How do bridges stay up?"])
messages = [%{role: "user", content: "Ticket #{:rand.uniform(1_000_000)}: #{question}"}]
```

To send real conversations from a benchmark dataset, read them from a file
once, in `c:Stampede.Scenario.setup/1`. Each line of the file can have
`"messages"`, ShareGPT's `"conversations"` or a `"prompt"`:

```elixir
def setup(_opts), do: Stampede.LLM.prompts_from_jsonl("prompts.jsonl", limit: 1_000)

def run(vu) do
  {:ok, _reply} = Stampede.LLM.chat(@url, model: @model, messages: Enum.random(vu.data))
end
```

When what matters is how long the prompt is, not what it says,
`Stampede.LLM.synthetic_prompt(500)` makes one of 500 words.

A user that keeps talking sends the whole conversation each time, which is
how prompts get long in real chats:

```elixir
def run(_vu) do
  first = [%{role: "user", content: "Tell me about Lisbon."}]
  {:ok, reply} = Stampede.LLM.chat(@url, model: @model, messages: first)

  Process.sleep(5_000)

  next = first ++ [%{role: "assistant", content: reply.content}, %{role: "user", content: "Where should I eat?"}]
  {:ok, _reply} = Stampede.LLM.chat(@url, model: @model, messages: next)
end
```

Some servers can be told to generate a fixed number of tokens, which makes
runs easier to compare. On vLLM, send `extra: %{ignore_eos: true}` along with
`max_tokens`. For hosted APIs, `:api_key` sends a bearer token. Careful there:
a load test spends real tokens, and real money.

## Reading the result

The two timings tell you different things:

  * **The first token gets slower, but the gaps between tokens don't.**
    Requests are queuing. Once one starts, it runs at full speed, so the
    server has too few slots, or too few replicas.
  * **The gaps between tokens get slower too.** The machine itself is running
    out of compute, because the requests in progress are sharing it.

Watch the load test as well. The summary warns you when the load test itself
is too busy to trust. With AI servers that's rare, since nearly all the work
is on the model's side.

## A real run

Here's how that looked on AWS: Ollama 0.40 on an 8-core Graviton machine with
16 GB and no GPU, serving the 397 MB `qwen2.5:0.5b` model, with Stampede on a
second machine. Each user asked a different question, read up to 128 tokens
and thought for 5 to 10 seconds. A step passed with the first token under 2
seconds and tokens under 200ms apart at p95, with no errors.

With Ollama's default settings:

| Chatting users | First token p95 | Between tokens p95 | Errors | |
|---:|---:|---:|---:|---|
| 2 | 465ms | 8ms | 0 | held |
| 4 | 1.10s | 8ms | 0 | held |
| **6** | **995ms** | **8ms** | **0** | **held** |
| 8 | 2.55s | 8ms | 0 | over |

Tokens stayed 8ms apart the whole way, while the first token kept getting
later. That's the queue from the last section, and Ollama's log explained it:
`OLLAMA_NUM_PARALLEL` is 1 by default, so it answers one person at a time and
everyone else waits. So I changed that one setting to 4 and ran it again:

| Chatting users | First token p95 | Between tokens p95 | Errors | |
|---:|---:|---:|---:|---|
| 6 | 580ms | 20ms | 0 | held |
| 8 | 848ms | 20ms | 0 | held |
| 10 | 421ms | 20ms | 0 | held |
| **12** | **1.51s** | **21ms** | **0** | **held** |
| 14 | 2.21s | 21ms | 0 | over |

Twice the users. Each reply streams a bit slower, since four share the CPU,
but 20ms a token is still far faster than anyone reads. Total throughput went
from about 70 to 125 tokens a second, and at 14 users the CPU was at 98%, so
that's the hardware's real limit.

A small model on CPU says little about a big model on GPUs, so don't read
these as numbers for your setup. Run it against yours. Everything from these
two runs is in
[`bench/million/results`](https://github.com/mandar1045/stampede/tree/main/bench/million/results),
and the scripts that set it up are `ollama.sh` and `run-llm.sh` in
[`bench/million/aws`](https://github.com/mandar1045/stampede/tree/main/bench/million/aws).
