defmodule Stampede.WebSocket.Connection do
  @moduledoc false

  # The Mint side of a WebSocket, shared by the Channels and plain clients.

  # Also returns the frames that came with the upgrade response, since a
  # server may send some right away.
  def connect(uri, path, opts) do
    {http_scheme, ws_scheme} = if uri.scheme == "wss", do: {:https, :wss}, else: {:http, :ws}
    timeout = opts[:connect_timeout]
    deadline = System.monotonic_time(:millisecond) + timeout
    transport_opts = Keyword.put_new(opts[:transport_opts], :timeout, timeout)

    with {:ok, conn} <-
           Mint.HTTP.connect(http_scheme, uri.host, uri.port,
             protocols: [:http1],
             transport_opts: transport_opts
           ),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws_scheme, conn, path, opts[:headers]),
         {:ok, conn, status, headers, data} <- await_upgrade(conn, ref, deadline, {nil, [], []}),
         {:ok, conn, websocket} <- Mint.WebSocket.new(conn, ref, status, headers),
         {:ok, websocket, frames} <- decode_early(conn, websocket, data) do
      {:ok, conn, ref, websocket, frames}
    else
      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Returns the frames in `message`, or :unknown if it is not for `conn`.
  def stream(conn, ref, websocket, message) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} -> decode(conn, ref, websocket, responses, [])
      {:error, conn, reason, _responses} -> {:error, conn, websocket, reason}
      :unknown -> :unknown
    end
  end

  def send_frame(conn, ref, websocket, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, data) do
      {:ok, conn, websocket}
    else
      {:error, %Mint.WebSocket{} = websocket, reason} -> {:error, conn, websocket, reason}
      {:error, conn, reason} -> {:error, conn, websocket, reason}
    end
  end

  defp decode(conn, ref, websocket, [{:data, ref, data} | responses], frames) do
    case Mint.WebSocket.decode(websocket, data) do
      {:ok, websocket, more} -> decode(conn, ref, websocket, responses, [frames, more])
      {:error, websocket, reason} -> {:error, conn, websocket, reason}
    end
  end

  defp decode(conn, ref, websocket, [_response | responses], frames) do
    decode(conn, ref, websocket, responses, frames)
  end

  defp decode(conn, _ref, websocket, [], frames) do
    {:ok, conn, websocket, List.flatten(frames)}
  end

  defp await_upgrade(conn, ref, deadline, response) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            case Enum.reduce(responses, {:more, response}, &upgrade_response(&1, ref, &2)) do
              {:done, {status, headers, data}} -> {:ok, conn, status, headers, data}
              {:more, response} -> await_upgrade(conn, ref, deadline, response)
            end

          {:error, conn, reason, _responses} ->
            {:error, conn, reason}

          :unknown ->
            await_upgrade(conn, ref, deadline, response)
        end
    after
      timeout -> {:error, conn, %Mint.TransportError{reason: :timeout}}
    end
  end

  # Frames sent right after the upgrade come in as its body.
  defp upgrade_response({:status, ref, status}, ref, {:more, {_status, headers, data}}),
    do: {:more, {status, headers, data}}

  defp upgrade_response({:headers, ref, more}, ref, {:more, {status, headers, data}}),
    do: {:more, {status, headers ++ more, data}}

  defp upgrade_response({:data, ref, more}, ref, {:more, {status, headers, data}}),
    do: {:more, {status, headers, [data, more]}}

  defp upgrade_response({:done, ref}, ref, {:more, response}), do: {:done, response}
  defp upgrade_response(_response, _ref, acc), do: acc

  defp decode_early(conn, websocket, data) do
    case Mint.WebSocket.decode(websocket, IO.iodata_to_binary(data)) do
      {:ok, websocket, frames} -> {:ok, websocket, frames}
      {:error, _websocket, reason} -> {:error, conn, reason}
    end
  end
end
