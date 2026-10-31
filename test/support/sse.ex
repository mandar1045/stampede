defmodule Stampede.TestEventsController do
  use Phoenix.Controller, formats: []

  import Plug.Conn

  # `count` events, the first after `first` milliseconds and then one every
  # `gap`, as a server streaming tokens would.
  def steady(conn, params) do
    count = integer(params, "count", 5)
    gap = integer(params, "gap", 0)
    conn = start(conn)
    Process.sleep(integer(params, "first", 0))

    Enum.reduce(1..count, conn, fn i, conn ->
      if i > 1, do: Process.sleep(gap)
      send_part(conn, "id: #{i}\ndata: token #{i}\n\n")
    end)
  end

  # Everything the standard allows, split awkwardly between parts: a line
  # cut in two, a "\r\n" cut between its halves, lines ending in "\r" alone,
  # a comment, a field without a colon, and an event the stream never ends.
  def tricky(conn, _params) do
    parts = [
      ": a comment\n",
      "event: greeting\ndata: hel",
      "lo\n\n",
      "data: first line\r\ndata: second line\r",
      "\n\r\n",
      "data: cr only\r\r",
      "id: 7\ndata:no space\n\n",
      "retry: 100\ndata\n\n",
      "data: unterminated"
    ]

    Enum.reduce(parts, start(conn), fn part, conn ->
      Process.sleep(5)
      send_part(conn, part)
    end)
  end

  # Sends one event, then drops the connection.
  def broken(conn, _params) do
    conn |> start() |> send_part("data: one\n\n")
    Process.sleep(20)
    exit(:normal)
  end

  def limited(conn, _params) do
    conn |> put_status(429) |> json(%{error: "rate limited"})
  end

  defp start(conn) do
    conn
    |> put_resp_content_type("text/event-stream")
    |> send_chunked(200)
  end

  # A client can leave halfway, as VUs do when a run ends.
  defp send_part(conn, part) do
    case chunk(conn, part) do
      {:ok, conn} -> conn
      {:error, _closed} -> conn
    end
  end

  defp integer(params, name, default) do
    case params[name] do
      nil -> default
      value when is_integer(value) -> value
      value -> String.to_integer(value)
    end
  end
end

# An API in OpenAI's format. The model's name picks how it behaves: the first
# token comes after 50ms, and the next ones every 10ms.
defmodule Stampede.TestLLMController do
  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  @first 50
  @gap 10

  def chat(conn, %{"model" => "limited"}) do
    conn |> put_status(429) |> json(%{error: %{message: "rate limited"}})
  end

  def chat(conn, %{"model" => "locked"} = params) do
    case get_req_header(conn, "authorization") do
      ["Bearer secret"] -> chat(conn, %{params | "model" => "mock"})
      _other -> conn |> put_status(401) |> json(%{error: %{message: "no key"}})
    end
  end

  # Replies with what it was sent, as its content.
  def chat(conn, %{"model" => "echo"} = params) do
    json(conn, completion(JSON.encode!(params), params))
  end

  def chat(conn, %{"stream" => false} = params) do
    json(conn, completion("Hello there", params))
  end

  def chat(conn, %{"model" => "empty"}) do
    conn |> start() |> send_data("[DONE]")
  end

  def chat(conn, %{"model" => "failing"}) do
    conn
    |> start()
    |> send_token("Hi")
    |> send_data(JSON.encode!(%{error: %{message: "out of memory"}}))
  end

  def chat(conn, %{"model" => "broken"}) do
    conn |> start() |> send_token("Hi")
    Process.sleep(20)
    exit(:normal)
  end

  def chat(conn, params) do
    tokens = params["max_tokens"] || 5
    conn = start(conn)
    Process.sleep(@first)

    conn =
      Enum.reduce(1..tokens, conn, fn i, conn ->
        if i > 1, do: Process.sleep(@gap)
        send_token(conn, "t#{i} ")
      end)

    conn = send_data(conn, delta(%{}, "stop"))

    conn =
      if params["model"] != "no-usage" and params["stream_options"]["include_usage"],
        do: send_data(conn, JSON.encode!(%{choices: [], usage: usage(tokens)})),
        else: conn

    send_data(conn, "[DONE]")
  end

  defp completion(text, params) do
    %{
      choices: [%{message: %{role: "assistant", content: text}, finish_reason: "stop"}],
      usage: usage(params["max_tokens"] || 2)
    }
  end

  defp usage(tokens), do: %{prompt_tokens: 7, completion_tokens: tokens}

  defp start(conn) do
    conn
    |> put_resp_content_type("text/event-stream")
    |> send_chunked(200)
  end

  defp send_token(conn, text), do: send_data(conn, delta(%{content: text}, nil))

  defp delta(delta, finish_reason) do
    JSON.encode!(%{choices: [%{delta: delta, finish_reason: finish_reason}]})
  end

  defp send_data(conn, data) do
    case chunk(conn, "data: #{data}\n\n") do
      {:ok, conn} -> conn
      {:error, _closed} -> conn
    end
  end
end
