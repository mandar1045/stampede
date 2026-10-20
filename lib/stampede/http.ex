defmodule Stampede.HTTP do
  @moduledoc false

  def get(url, headers, opts) do
    uri = URI.parse(url)
    timeout = Keyword.fetch!(opts, :timeout)
    deadline = System.monotonic_time(:millisecond) + timeout
    scheme = if uri.scheme == "https", do: :https, else: :http
    transport_opts = Keyword.put_new(opts[:transport_opts], :timeout, timeout)

    with {:ok, conn} <-
           Mint.HTTP.connect(scheme, uri.host, uri.port,
             protocols: [:http1],
             transport_opts: transport_opts
           ) do
      {result, conn} = request(conn, target(uri), headers, deadline)
      Mint.HTTP.close(conn)
      result
    end
  end

  defp request(conn, target, headers, deadline) do
    case Mint.HTTP.request(conn, "GET", target, headers, nil) do
      {:ok, conn, ref} ->
        receive_response(conn, ref, deadline, %{status: nil, headers: [], body: []})

      {:error, conn, reason} ->
        {{:error, reason}, conn}
    end
  end

  # This runs in the caller's process, so it only takes messages from its own
  # socket and leaves everything else in the mailbox.
  defp receive_response(conn, ref, deadline, response) do
    socket = Mint.HTTP.get_socket(conn)
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      message
      when is_tuple(message) and tuple_size(message) >= 2 and elem(message, 1) == socket ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, responses} ->
            case collect(responses, ref, response) do
              {:done, response} -> {{:ok, finish(response)}, conn}
              {:more, response} -> receive_response(conn, ref, deadline, response)
            end

          {:error, conn, reason, _responses} ->
            {{:error, reason}, conn}

          :unknown ->
            receive_response(conn, ref, deadline, response)
        end
    after
      timeout -> {{:error, %Mint.TransportError{reason: :timeout}}, conn}
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

  defp finish(response), do: %{response | body: IO.iodata_to_binary(response.body)}

  defp target(%URI{path: path, query: nil}), do: path || "/"
  defp target(%URI{path: path, query: query}), do: "#{path || "/"}?#{query}"
end
