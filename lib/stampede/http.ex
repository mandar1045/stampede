defmodule Stampede.HTTP do
  @moduledoc """
  An HTTP client for load tests.

      {:ok, %{status: 200, body: body}} = Stampede.HTTP.get("http://localhost:4000/api/posts")
      {:ok, %{status: 201}} = Stampede.HTTP.post("http://localhost:4000/api/posts", json: %{title: "Hi"})

  Responses are maps with the `:status`, the `:headers`, with lowercase
  names, and the `:body`.

  Each VU keeps a connection open to every server it talks to and sends its
  next request on it, as a browser does. When the server closed it in the
  meantime, a new one is opened, and a request that is safe to repeat (GET,
  HEAD, PUT, DELETE or OPTIONS) is sent again on it.

  ## Metrics

  Inside a run, requests record:

    * `"http.request"` - how long each response took, whatever its status
    * `"http.request.errors"` - requests that failed, or whose response had a
      status of 400 or more
  """

  alias Stampede.Metrics

  @type response :: %{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @methods [:get, :head, :post, :put, :patch, :delete, :options]
  @idempotent [:get, :head, :put, :delete, :options]

  @doc "Sends a GET request. See `request/3`."
  @spec get(String.t(), keyword()) :: {:ok, response()} | {:error, term()}
  def get(url, opts \\ []), do: request(:get, url, opts)

  @doc "Sends a POST request. See `request/3`."
  @spec post(String.t(), keyword()) :: {:ok, response()} | {:error, term()}
  def post(url, opts \\ []), do: request(:post, url, opts)

  @doc "Sends a PUT request. See `request/3`."
  @spec put(String.t(), keyword()) :: {:ok, response()} | {:error, term()}
  def put(url, opts \\ []), do: request(:put, url, opts)

  @doc "Sends a PATCH request. See `request/3`."
  @spec patch(String.t(), keyword()) :: {:ok, response()} | {:error, term()}
  def patch(url, opts \\ []), do: request(:patch, url, opts)

  @doc "Sends a DELETE request. See `request/3`."
  @spec delete(String.t(), keyword()) :: {:ok, response()} | {:error, term()}
  def delete(url, opts \\ []), do: request(:delete, url, opts)

  @doc """
  Sends a `method` request to `url` and waits for the whole response.

  Returns `{:ok, response}` whatever the status, and `{:error, reason}` when
  there is no response, such as a `Mint.TransportError`.

  ## Options

    * `:headers` - a list of `{name, value}` headers
    * `:body` - the body, as iodata
    * `:json` - a term to send as JSON instead of a `:body`, with a
      `content-type` of `application/json` unless one is given
    * `:timeout` - how long to wait for the response, in milliseconds.
      Defaults to `5_000`.
    * `:metric` - the timing to record the request as, or `nil` to record
      nothing. Defaults to `"http.request"`.
    * `:transport_opts` - options for `:gen_tcp` or `:ssl`, given to
      `Mint.HTTP.connect/4`
  """
  @spec request(atom(), String.t(), keyword()) :: {:ok, response()} | {:error, term()}
  def request(method, url, opts \\ []) when method in @methods and is_binary(url) do
    opts =
      Keyword.validate!(opts,
        headers: [],
        body: nil,
        json: nil,
        timeout: 5_000,
        metric: "http.request",
        transport_opts: []
      )

    uri = URI.parse(url)

    if uri.scheme not in ["http", "https"] or is_nil(uri.host) do
      raise ArgumentError, "expected an http:// or https:// URL, got: #{inspect(url)}"
    end

    {headers, body} = encode_body(opts)
    started_at = System.monotonic_time()
    result = send_request(%{method: method, uri: uri, headers: headers, body: body}, opts)
    record(result, opts[:metric], started_at)
    result
  end

  defp encode_body(opts) do
    case opts[:json] do
      nil ->
        {opts[:headers], opts[:body]}

      term ->
        has_type? =
          Enum.any?(opts[:headers], fn {name, _value} ->
            String.downcase(name) == "content-type"
          end)

        headers =
          if has_type?,
            do: opts[:headers],
            else: [{"content-type", "application/json"} | opts[:headers]]

        {headers, JSON.encode_to_iodata!(term)}
    end
  end

  defp send_request(request, opts) do
    key =
      {__MODULE__, request.uri.scheme, request.uri.host, request.uri.port, opts[:transport_opts]}

    deadline = System.monotonic_time(:millisecond) + opts[:timeout]

    case Process.delete(key) do
      nil ->
        connect_and_exchange(key, request, deadline, opts)

      conn ->
        case conn |> refresh() |> exchange(request, deadline) do
          {:stale, conn} when request.method in @idempotent ->
            Mint.HTTP.close(conn)
            connect_and_exchange(key, request, deadline, opts)

          result ->
            finish(key, result)
        end
    end
  end

  defp connect_and_exchange(key, request, deadline, opts) do
    scheme = if request.uri.scheme == "https", do: :https, else: :http
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)
    transport_opts = Keyword.put_new(opts[:transport_opts], :timeout, timeout)

    with {:ok, address} <- Stampede.Address.resolve(request.uri.host),
         {:ok, conn} <-
           Mint.HTTP.connect(scheme, address, request.uri.port,
             hostname: request.uri.host,
             protocols: [:http1],
             transport_opts: transport_opts
           ) do
      finish(key, exchange(conn, request, deadline))
    end
  end

  # Connections stay open in the VU's process between requests, so anything
  # the server sent meanwhile, such as closing them, is read before reusing one.
  defp refresh(conn) do
    socket = Mint.HTTP.get_socket(conn)

    receive do
      message
      when is_tuple(message) and tuple_size(message) >= 2 and elem(message, 1) == socket ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, _responses} -> refresh(conn)
          {:error, conn, _reason, _responses} -> conn
          :unknown -> conn
        end
    after
      0 -> conn
    end
  end

  # Returns {:stale, conn} when the connection was closed before any of the
  # response arrived, so the request can be sent again elsewhere.
  defp exchange(conn, request, deadline) do
    method = request.method |> Atom.to_string() |> String.upcase()

    with true <- Mint.HTTP.open?(conn),
         {:ok, conn, ref} <-
           Mint.HTTP.request(conn, method, target(request.uri), request.headers, request.body) do
      receive_response(conn, ref, deadline, %{status: nil, headers: [], body: []})
    else
      false -> {:stale, conn}
      {:error, conn, _reason} -> {:stale, conn}
    end
  end

  defp receive_response(conn, ref, deadline, response) do
    socket = Mint.HTTP.get_socket(conn)
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      message
      when is_tuple(message) and tuple_size(message) >= 2 and elem(message, 1) == socket ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, responses} ->
            case collect(responses, ref, response) do
              {:done, response} ->
                {:ok, %{response | body: IO.iodata_to_binary(response.body)}, conn}

              {:more, response} ->
                receive_response(conn, ref, deadline, response)
            end

          {:error, conn, reason, _responses} ->
            if response.status, do: {:error, reason, conn}, else: {:stale, conn}

          :unknown ->
            receive_response(conn, ref, deadline, response)
        end
    after
      timeout -> {:error, %Mint.TransportError{reason: :timeout}, conn}
    end
  end

  defp collect(responses, ref, response) do
    Enum.reduce(responses, {:more, response}, fn
      {:status, ^ref, status}, {:more, response} ->
        {:more, %{response | status: status}}

      {:headers, ^ref, headers}, {:more, response} ->
        {:more, %{response | headers: response.headers ++ headers}}

      {:data, ^ref, data}, {:more, response} ->
        {:more, %{response | body: [response.body | data]}}

      {:done, ^ref}, {:more, response} ->
        {:done, response}

      _response, acc ->
        acc
    end)
  end

  defp finish(key, {:ok, response, conn}) do
    if Mint.HTTP.open?(conn), do: Process.put(key, conn), else: Mint.HTTP.close(conn)
    {:ok, response}
  end

  defp finish(_key, {:error, reason, conn}) do
    Mint.HTTP.close(conn)
    {:error, reason}
  end

  defp finish(_key, {:stale, conn}) do
    Mint.HTTP.close(conn)
    {:error, %Mint.TransportError{reason: :closed}}
  end

  defp record(_result, nil, _started_at), do: :ok

  defp record(result, metric, started_at) do
    metrics = Metrics.current()

    case result do
      {:ok, %{status: status}} ->
        Metrics.record_since(metrics, metric, started_at)
        if status >= 400, do: Metrics.increment(metrics, metric <> ".errors")

      {:error, _reason} ->
        Metrics.increment(metrics, metric <> ".errors")
    end
  end

  defp target(%URI{path: path, query: nil}), do: path || "/"
  defp target(%URI{path: path, query: query}), do: "#{path || "/"}?#{query}"
end
