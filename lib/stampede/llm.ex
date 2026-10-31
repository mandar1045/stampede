defmodule Stampede.LLM do
  @moduledoc """
  A client for AI chat APIs in OpenAI's format, such as Ollama, vLLM,
  llama.cpp, LM Studio or OpenAI itself, to find out how many people your
  model server can chat with at once.

      {:ok, reply} =
        Stampede.LLM.chat("http://localhost:11434/v1",
          model: "qwen2.5:0.5b",
          messages: [%{role: "user", content: "Why is the sky blue?"}],
          max_tokens: 100
        )

      reply.content

  The server can be anything that speaks this format. Scenarios are in
  Elixir, but the server doesn't have to be.

  ## Metrics

  Inside a run, chats record the same measures as `vllm bench serve`, so
  numbers from the two compare directly:

    * `"llm.ttft"` - time to first token, from sending the request to the
      first chunk with content
    * `"llm.itl"` - inter-token latency, every gap between two chunks with
      content
    * `"llm.tpot"` - time per output token, once per request with more than
      one: the time after the first token over the tokens after the first
    * `"llm.request"` - the whole request, from start to end
    * `"llm.request.errors"` - requests that failed: a status of 400 or more,
      a stream that broke or reported an error, or no tokens at all
    * `"llm.tokens.output"` and `"llm.tokens.input"` - tokens generated and
      read. Their `:rate` is the tokens per second of the whole run.

  Token counts are what the server reports, when it does. Otherwise, the
  output is counted as one token per chunk, which is close for most servers,
  and the input isn't counted.

  Requests without streaming only record `"llm.request"`, its errors and the
  token counts, as there's no first token to time.
  """

  alias Stampede.{HTTP, Metrics, SSE}

  @type reply :: %{
          content: String.t(),
          usage: %{input: non_neg_integer() | nil, output: non_neg_integer()},
          ttft: float() | nil,
          finish_reason: String.t() | nil
        }

  @doc """
  Sends a chat to the API at `url` and reads the whole reply.

  `url` is the API's base, such as `"http://localhost:8000/v1"`, or the full
  URL ending in `/chat/completions`.

  Returns `{:ok, reply}`, with the `:content`, the tokens in `:usage`, the
  `:ttft` in milliseconds and the `:finish_reason`. Otherwise, returns
  `{:error, reason}`: `{:status, status, body}` for a status of 400 or more,
  `{:stream, error}` for an error sent in the stream, `:no_tokens` for a reply
  without any, or a `Mint.TransportError` when the connection failed.

  ## Options

    * `:model` - the model's name, required
    * `:messages` - the conversation, required, as a list of maps with a
      `:role` and `:content`
    * `:max_tokens` - the most tokens to generate
    * `:temperature` - the sampling temperature
    * `:api_key` - sent as a bearer token
    * `:headers` - extra headers
    * `:stream` - whether to stream the reply. Defaults to `true`.
    * `:timeout` - how long the whole reply may take, in milliseconds.
      Defaults to `120_000`.
    * `:extra` - a map of other fields to send, such as vLLM's
      `%{ignore_eos: true}` for replies of a fixed length
    * `:transport_opts` - options for `:gen_tcp` or `:ssl`, given to
      `Mint.HTTP.connect/4`
  """
  @spec chat(String.t(), keyword()) :: {:ok, reply()} | {:error, term()}
  def chat(url, opts) when is_binary(url) do
    opts =
      Keyword.validate!(opts, [
        :model,
        :messages,
        :max_tokens,
        :temperature,
        :api_key,
        headers: [],
        stream: true,
        timeout: 120_000,
        extra: %{},
        transport_opts: []
      ])

    request_opts = [
      json: body(opts),
      headers: headers(opts),
      timeout: opts[:timeout],
      metric: nil,
      transport_opts: opts[:transport_opts]
    ]

    started_at = System.monotonic_time()

    result =
      if opts[:stream],
        do: stream(completions_url(url), request_opts),
        else: complete(completions_url(url), request_opts)

    record(result, started_at)
  end

  @doc """
  Reads conversations to send from a file with one JSON object on each line,
  returning a list of `:messages` for `chat/2`.

  Each line can have its conversation as `"messages"`, in OpenAI's format, as
  `"conversations"`, in ShareGPT's format (with `"from"` and `"value"`), or as
  a single `"prompt"`. With `"conversations"`, the conversation stops before
  the last reply from the model, so that it's the server's turn to answer.

  ## Options

    * `:limit` - the most conversations to read
  """
  @spec prompts_from_jsonl(Path.t(), keyword()) :: [[map()]]
  def prompts_from_jsonl(path, opts \\ []) do
    opts = Keyword.validate!(opts, limit: :infinity)

    path
    |> File.stream!()
    |> Stream.reject(&(String.trim(&1) == ""))
    |> Stream.map(&conversation!(JSON.decode!(&1), path))
    |> limit(opts[:limit])
    |> Enum.to_list()
  end

  defp limit(stream, :infinity), do: stream
  defp limit(stream, count), do: Stream.take(stream, count)

  defp conversation!(%{"messages" => [_ | _] = messages}, _path) do
    Enum.map(messages, &%{role: &1["role"], content: &1["content"]})
  end

  defp conversation!(%{"conversations" => [_ | _] = turns}, _path) do
    turns
    |> Enum.map(fn turn -> %{role: role(turn["from"]), content: turn["value"]} end)
    |> Enum.reverse()
    |> Enum.drop_while(&(&1.role != "user"))
    |> Enum.reverse()
  end

  defp conversation!(%{"prompt" => prompt}, _path) when is_binary(prompt) do
    [%{role: "user", content: prompt}]
  end

  defp conversation!(line, path) do
    raise ArgumentError,
          "expected each line of #{path} to have \"messages\", \"conversations\" or " <>
            "\"prompt\", got: #{inspect(line)}"
  end

  defp role(from) when from in ["human", "user"], do: "user"
  defp role(from) when from in ["gpt", "assistant", "chatgpt"], do: "assistant"
  defp role(from), do: from

  @words ~w(the server answers every question about mountains rivers cities history
            music science language gardens oceans machines stories weather planets
            bridges forests markets letters teachers engines islands recipes)

  @doc """
  Returns a prompt of random words, `words` long, for load tests where the
  size of the prompt matters and what it says doesn't.
  """
  @spec synthetic_prompt(pos_integer()) :: String.t()
  def synthetic_prompt(words) when is_integer(words) and words > 0 do
    Enum.map_join(1..words, " ", fn _word -> Enum.random(@words) end)
  end

  defp completions_url(url) do
    url = String.trim_trailing(url, "/")
    if String.ends_with?(url, "/chat/completions"), do: url, else: url <> "/chat/completions"
  end

  defp body(opts) do
    for key <- [:max_tokens, :temperature], opts[key] != nil, into: base_body(opts) do
      {key, opts[key]}
    end
    |> Map.merge(Map.new(opts[:extra]))
  end

  defp base_body(opts) do
    for key <- [:model, :messages], opts[key] == nil do
      raise ArgumentError, "expected #{inspect(key)} to be given"
    end

    body = %{model: opts[:model], messages: opts[:messages], stream: opts[:stream]}

    if opts[:stream],
      do: Map.put(body, :stream_options, %{include_usage: true}),
      else: body
  end

  defp headers(opts) do
    case opts[:api_key] do
      nil -> opts[:headers]
      key -> [{"authorization", "Bearer #{key}"} | opts[:headers]]
    end
  end

  defp stream(url, opts) do
    case SSE.post(url, opts) do
      {:ok, %{status: status, body: body}} when status >= 400 -> {:error, {:status, status, body}}
      {:ok, %{events: events}} -> read_events(events)
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_events(events) do
    chunks = for %{data: data, at: at} <- events, data != "[DONE]", do: {decode(data), at}

    case Enum.find_value(chunks, fn {chunk, _at} -> chunk["error"] end) do
      nil -> read_chunks(chunks)
      error -> {:error, {:stream, error}}
    end
  end

  defp read_chunks(chunks) do
    tokens =
      for {chunk, at} <- chunks, text = delta(chunk), text != "", do: {text, at}

    case tokens do
      [] ->
        {:error, :no_tokens}

      [{_text, ttft} | _] ->
        {:ok,
         %{
           content: tokens |> Enum.map(&elem(&1, 0)) |> IO.iodata_to_binary(),
           usage: usage(Enum.find_value(chunks, fn {chunk, _at} -> chunk["usage"] end), tokens),
           ttft: ttft,
           finish_reason:
             Enum.find_value(chunks, fn {chunk, _at} -> choice(chunk)["finish_reason"] end)
         }, Enum.map(tokens, &elem(&1, 1))}
    end
  end

  defp delta(chunk), do: choice(chunk)["delta"]["content"]

  defp choice(chunk) do
    case chunk["choices"] do
      [choice | _] -> choice
      _none -> %{}
    end
  end

  defp usage(nil, tokens), do: %{input: nil, output: length(tokens)}

  defp usage(usage, tokens) do
    %{input: usage["prompt_tokens"], output: usage["completion_tokens"] || length(tokens)}
  end

  # A chunk that isn't JSON says nothing, so it counts for nothing.
  defp decode(data) do
    case JSON.decode(data) do
      {:ok, chunk} when is_map(chunk) -> chunk
      _other -> %{}
    end
  end

  defp complete(url, opts) do
    case HTTP.post(url, opts) do
      {:ok, %{status: status, body: body}} when status >= 400 ->
        {:error, {:status, status, body}}

      {:ok, %{body: body}} ->
        completion = decode(body)

        case choice(completion)["message"]["content"] do
          text when is_binary(text) and text != "" ->
            {:ok,
             %{
               content: text,
               usage: usage(completion["usage"], [text]),
               ttft: nil,
               finish_reason: choice(completion)["finish_reason"]
             }, []}

          _none ->
            {:error, :no_tokens}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record({:ok, reply, times}, started_at) do
    metrics = Metrics.current()
    duration = System.monotonic_time() - started_at
    Metrics.record(metrics, "llm.request", duration)
    Metrics.increment(metrics, "llm.tokens.output", reply.usage.output)
    if reply.usage.input, do: Metrics.increment(metrics, "llm.tokens.input", reply.usage.input)

    if reply.ttft do
      Metrics.record(metrics, "llm.ttft", native(reply.ttft))

      for [earlier, later] <- Enum.chunk_every(times, 2, 1, :discard) do
        Metrics.record(metrics, "llm.itl", native(later - earlier))
      end

      if reply.usage.output > 1 do
        after_first = duration - native(reply.ttft)
        Metrics.record(metrics, "llm.tpot", max(div(after_first, reply.usage.output - 1), 0))
      end
    end

    {:ok, reply}
  end

  defp record({:error, reason}, _started_at) do
    Metrics.increment(Metrics.current(), "llm.request.errors")
    {:error, reason}
  end

  defp native(milliseconds),
    do: System.convert_time_unit(round(milliseconds * 1000), :microsecond, :native)
end
