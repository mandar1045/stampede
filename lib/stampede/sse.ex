defmodule Stampede.SSE do
  @moduledoc """
  A client for Server-Sent Events, the streams that AI chat APIs, live
  feeds and many dashboards send their updates on.

      {:ok, response} = Stampede.SSE.get("http://localhost:4000/api/updates")
      [%{event: "message", data: data, at: at} | _] = response.events

  Requests go through `Stampede.HTTP`, so each VU keeps its connection to a
  server open between them, as a browser does. The response has the
  `:status`, the `:headers`, the raw `:body`, and the `:events` read from
  it, in order. Each event has:

    * `:event` - its type, `"message"` unless the server set another
    * `:data` - its data, with the lines of a multi-line event joined by
      `"\\n"`
    * `:id` - the last id the server sent, or `nil`
    * `:at` - when it arrived, in milliseconds from sending the request

  Events follow the HTML standard's rules for `text/event-stream`. An event
  the stream ended in the middle of, without the blank line after it, still
  counts, since some servers end that way.

  ## Metrics

  Inside a run, requests record:

    * `"sse.request"` - from sending the request to the end of the stream
    * `"sse.first_event"` - from sending the request to the first event
    * `"sse.events"` - how many events arrived
    * `"sse.request.errors"` - requests that failed, or whose response had a
      status of 400 or more
  """

  alias Stampede.{HTTP, Metrics}

  @type event :: %{event: String.t(), data: String.t(), id: String.t() | nil, at: float()}

  @type response :: %{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: binary(),
          events: [event()]
        }

  @doc "Opens a stream with a GET request. See `request/3`."
  @spec get(String.t(), keyword()) :: {:ok, response()} | {:error, term()}
  def get(url, opts \\ []), do: request(:get, url, opts)

  @doc "Opens a stream with a POST request. See `request/3`."
  @spec post(String.t(), keyword()) :: {:ok, response()} | {:error, term()}
  def post(url, opts \\ []), do: request(:post, url, opts)

  @doc """
  Sends a `method` request to `url` and reads the events it streams back,
  until the server ends the stream.

  Returns `{:ok, response}` whatever the status, and `{:error, reason}` when
  the stream failed, such as a `Mint.TransportError` when the connection
  closed before the end.

  ## Options

    * `:headers` - a list of `{name, value}` headers. An `accept` header of
      `text/event-stream` is added unless one is given.
    * `:body` - the body, as iodata
    * `:json` - a term to send as JSON instead of a `:body`
    * `:timeout` - how long the whole stream may take, in milliseconds.
      Defaults to `60_000`.
    * `:metric` - the prefix of the metrics to record, or `nil` to record
      nothing. Defaults to `"sse"`.
    * `:transport_opts` - options for `:gen_tcp` or `:ssl`, given to
      `Mint.HTTP.connect/4`
  """
  @spec request(atom(), String.t(), keyword()) :: {:ok, response()} | {:error, term()}
  def request(method, url, opts \\ []) do
    opts =
      Keyword.validate!(opts,
        headers: [],
        body: nil,
        json: nil,
        timeout: 60_000,
        metric: "sse",
        transport_opts: []
      )

    {metric, opts} = Keyword.pop(opts, :metric)
    opts = Keyword.update!(opts, :headers, &accept_events/1)
    started_at = System.monotonic_time()
    into = {Stampede.SSE.Parser.new(started_at), &Stampede.SSE.Parser.feed/2}

    result =
      case HTTP.stream(method, url, [metric: nil] ++ opts, into) do
        {:ok, %{body: parser} = response} ->
          {events, body} = Stampede.SSE.Parser.finish(parser)
          {:ok, Map.merge(response, %{body: body, events: events})}

        {:error, reason} ->
          {:error, reason}
      end

    record(result, metric, started_at)
    result
  end

  defp accept_events(headers) do
    if Enum.any?(headers, fn {name, _value} -> String.downcase(name) == "accept" end),
      do: headers,
      else: [{"accept", "text/event-stream"} | headers]
  end

  defp record(_result, nil, _started_at), do: :ok

  defp record(result, metric, started_at) do
    metrics = Metrics.current()

    case result do
      {:ok, %{status: status, events: events}} ->
        Metrics.record_since(metrics, metric <> ".request", started_at)
        if status >= 400, do: Metrics.increment(metrics, metric <> ".request.errors")

        with [first | _] <- events do
          Metrics.record(metrics, metric <> ".first_event", native(first.at))
          Metrics.increment(metrics, metric <> ".events", length(events))
        end

      {:error, _reason} ->
        Metrics.increment(metrics, metric <> ".request.errors")
    end

    :ok
  end

  defp native(milliseconds),
    do: System.convert_time_unit(round(milliseconds * 1000), :microsecond, :native)
end

defmodule Stampede.SSE.Parser do
  @moduledoc false

  # Reads a text/event-stream as it arrives, part by part. Lines end with
  # "\r\n", "\n" or "\r", and a line can be split between two parts, even
  # between its "\r" and "\n".

  defstruct [:started_at, at: 0.0, buffer: "", type: nil, data: [], id: nil, events: [], raw: []]

  def new(started_at), do: %__MODULE__{started_at: started_at}

  def feed(chunk, parser) do
    at = milliseconds_since(parser.started_at)
    text = parser.buffer <> chunk

    # A "\r" at the end may be the first half of a "\r\n".
    {text, pending} =
      if String.ends_with?(text, "\r"),
        do: {binary_part(text, 0, byte_size(text) - 1), "\r"},
        else: {text, ""}

    {lines, [rest]} = text |> String.split(["\r\n", "\n", "\r"]) |> Enum.split(-1)
    parser = %{parser | at: at, raw: [parser.raw | chunk]}
    parser = Enum.reduce(lines, parser, &line/2)
    %{parser | buffer: rest <> pending}
  end

  def finish(parser) do
    parser =
      case String.trim_trailing(parser.buffer, "\r") do
        "" -> parser
        last -> line(last, parser)
      end

    parser = dispatch(parser)
    {Enum.reverse(parser.events), IO.iodata_to_binary(parser.raw)}
  end

  defp line("", parser), do: dispatch(parser)
  defp line(":" <> _comment, parser), do: parser

  defp line(line, parser) do
    {field, value} =
      case :binary.split(line, ":") do
        [field, " " <> value] -> {field, value}
        [field, value] -> {field, value}
        [field] -> {field, ""}
      end

    case field do
      "data" -> %{parser | data: [value | parser.data]}
      "event" -> %{parser | type: value}
      "id" -> if String.contains?(value, <<0>>), do: parser, else: %{parser | id: value}
      _retry_or_unknown -> parser
    end
  end

  defp dispatch(%{data: []} = parser), do: %{parser | type: nil}

  defp dispatch(parser) do
    event = %{
      event: parser.type || "message",
      data: parser.data |> Enum.reverse() |> Enum.join("\n"),
      id: parser.id,
      at: parser.at
    }

    %{parser | events: [event | parser.events], data: [], type: nil}
  end

  defp milliseconds_since(started_at) do
    System.convert_time_unit(System.monotonic_time() - started_at, :native, :microsecond) / 1000
  end
end
