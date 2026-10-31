defmodule Stampede.LLMTest do
  use ExUnit.Case, async: true

  alias Stampede.LLM

  defp url(path \\ "/v1"), do: Stampede.TestEndpoint.page_url(path)

  defp chat(model, opts \\ []) do
    LLM.chat(url(), [model: model, messages: [%{role: "user", content: "Hi"}]] ++ opts)
  end

  test "reads a streamed reply, with its first token's time and usage" do
    assert {:ok, reply} = chat("mock", max_tokens: 4)

    assert reply.content == "t1 t2 t3 t4 "
    assert reply.usage == %{input: 7, output: 4}
    assert reply.finish_reason == "stop"
    assert reply.ttft >= 50
  end

  test "counts chunks when the server doesn't report usage" do
    assert {:ok, %{usage: %{input: nil, output: 3}}} = chat("no-usage", max_tokens: 3)
  end

  test "takes the API's base or its full URL, with or without a slash" do
    for path <- ["/v1", "/v1/", "/v1/chat/completions"] do
      assert {:ok, _reply} =
               LLM.chat(url(path), model: "mock", messages: [], max_tokens: 1)
    end
  end

  test "sends the options, the extra fields and the key" do
    assert {:ok, %{content: content, ttft: nil}} =
             chat("echo",
               stream: false,
               max_tokens: 9,
               temperature: 0.5,
               extra: %{ignore_eos: true}
             )

    assert %{"max_tokens" => 9, "temperature" => 0.5, "ignore_eos" => true, "stream" => false} =
             sent = JSON.decode!(content)

    refute Map.has_key?(sent, "stream_options")

    assert {:error, {:status, 401, _body}} = chat("locked")
    assert {:ok, _reply} = chat("locked", api_key: "secret")
  end

  test "reads replies without streaming" do
    assert {:ok, reply} = chat("mock", stream: false, max_tokens: 2)
    assert %{content: "Hello there", ttft: nil, finish_reason: "stop"} = reply
    assert reply.usage == %{input: 7, output: 2}
  end

  # The server logs dropping the broken stream's connection.
  @tag :capture_log
  test "returns what went wrong" do
    assert {:error, {:status, 429, body}} = chat("limited")
    assert body =~ "rate limited"
    assert {:error, {:stream, %{"message" => "out of memory"}}} = chat("failing")
    assert {:error, :no_tokens} = chat("empty")
    assert {:error, %Mint.TransportError{}} = chat("broken")
    assert {:error, %Mint.TransportError{reason: :timeout}} = chat("mock", timeout: 20)
  end

  @tag :tmp_dir
  test "reads conversations from JSONL files", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "prompts.jsonl")

    File.write!(path, """
    {"prompt": "Why is the sky blue?"}
    {"messages": [{"role": "system", "content": "Be brief"}, {"role": "user", "content": "Hi"}]}

    {"conversations": [{"from": "human", "value": "Hi"}, {"from": "gpt", "value": "Hello"}]}
    {"conversations": [{"from": "human", "value": "A"}, {"from": "gpt", "value": "B"}, {"from": "human", "value": "C"}]}
    """)

    assert LLM.prompts_from_jsonl(path) == [
             [%{role: "user", content: "Why is the sky blue?"}],
             [%{role: "system", content: "Be brief"}, %{role: "user", content: "Hi"}],
             [%{role: "user", content: "Hi"}],
             [
               %{role: "user", content: "A"},
               %{role: "assistant", content: "B"},
               %{role: "user", content: "C"}
             ]
           ]

    assert [_, _] = LLM.prompts_from_jsonl(path, limit: 2)

    File.write!(path, ~s({"text": "nope"}\n))
    assert_raise ArgumentError, ~r/to have "messages"/, fn -> LLM.prompts_from_jsonl(path) end
  end

  test "makes prompts of a given length" do
    assert LLM.synthetic_prompt(50) |> String.split() |> length() == 50
  end

  test "raises without a model or messages" do
    assert_raise ArgumentError, ~r/:model to be given/, fn -> LLM.chat(url(), messages: []) end
    assert_raise ArgumentError, ~r/:messages to be given/, fn -> LLM.chat(url(), model: "m") end
  end

  defmodule Chat do
    use Stampede.Scenario

    @impl true
    def run(_vu) do
      {:ok, _reply} =
        Stampede.LLM.chat(Stampede.TestEndpoint.page_url("/v1"),
          model: "mock",
          messages: [%{role: "user", content: "Hi"}],
          max_tokens: 5
        )
    end
  end

  defmodule Limited do
    use Stampede.Scenario

    @impl true
    def run(_vu) do
      Stampede.LLM.chat(Stampede.TestEndpoint.page_url("/v1"), model: "limited", messages: [])
    end
  end

  test "records tokens and their timing in a run" do
    result = Stampede.run(Chat, vus: 2, duration: 1_000)

    requests = result.metrics["llm.request"].count
    assert requests >= 4
    assert result.metrics["llm.ttft"].count == requests
    assert result.metrics["llm.ttft"].p50 >= 50
    assert result.metrics["llm.itl"].count == 4 * requests
    assert result.metrics["llm.itl"].p50 >= 8
    assert result.metrics["llm.tpot"].count == requests
    assert result.metrics["llm.tpot"].p50 >= 8
    assert result.metrics["llm.tokens.output"].count == 5 * requests
    assert result.metrics["llm.tokens.input"].count == 7 * requests
    assert result.metrics["llm.tokens.output"].rate > 0

    html = Stampede.Reporter.to_html(result)
    assert html =~ "<span>TTFT p95</span>"
    assert html =~ "<span>Inter-token p95</span>"
    assert html =~ "<span>Tokens per second</span>"

    errors = Stampede.run(Limited, vus: 1, duration: 200).metrics
    assert errors["llm.request.errors"].count > 0
    refute Map.has_key?(errors, "llm.request")
  end
end
