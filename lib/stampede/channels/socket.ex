defmodule Stampede.Channels.Socket do
  @moduledoc false

  use GenServer

  alias Stampede.Channels.{Message, Serializer}
  alias Stampede.Metrics

  @inbox_limit 1_000

  defstruct [
    :conn,
    :ref,
    :websocket,
    :vsn,
    :metrics,
    :heartbeat_interval,
    :heartbeat_ref,
    next_ref: 0,
    joins: %{},
    pending: %{},
    waiters: [],
    inbox: :queue.new(),
    inbox_size: 0
  ]

  def start_link(uri, path, vsn, opts) do
    GenServer.start_link(__MODULE__, {uri, path, vsn, opts, Metrics.current()})
  end

  def request(socket, request) do
    GenServer.call(socket, request, :infinity)
  catch
    :exit, _reason -> {:error, :closed}
  end

  @impl true
  def init({uri, path, vsn, opts, metrics}) do
    started_at = System.monotonic_time()

    case connect(uri, path, opts) do
      {:ok, conn, ref, websocket} ->
        Metrics.record_since(metrics, "ws.connect", started_at)

        state = %__MODULE__{
          conn: conn,
          ref: ref,
          websocket: websocket,
          vsn: vsn,
          metrics: metrics,
          heartbeat_interval: opts[:heartbeat_interval]
        }

        {:ok, schedule_heartbeat(state)}

      {:error, reason} ->
        Metrics.increment(metrics, "ws.connect.errors")
        {:error, reason}
    end
  end

  @impl true
  def handle_call({:join, topic, payload, opts}, from, state) do
    {ref, state} = next_ref(state)
    message = %Message{join_ref: ref, ref: ref, topic: topic, event: "phx_join", payload: payload}
    send_request(state, message, from, :join, opts)
  end

  def handle_call({:push, topic, event, payload, opts}, from, state) do
    {ref, state} = next_ref(state)

    message = %Message{
      join_ref: state.joins[topic],
      ref: ref,
      topic: topic,
      event: event,
      payload: payload
    }

    send_request(state, message, from, :push, opts)
  end

  def handle_call({:leave, topic, opts}, from, state) do
    {ref, state} = next_ref(state)

    message = %Message{
      join_ref: state.joins[topic],
      ref: ref,
      topic: topic,
      event: "phx_leave",
      payload: %{}
    }

    send_request(state, message, from, :leave, opts)
  end

  def handle_call({:await, topic, event, timeout}, from, state) do
    case take_message(state, topic, event) do
      {:ok, message, state} ->
        {:reply, {:ok, message.payload}, state}

      :error ->
        timer = start_timer({:await_timeout, from}, timeout)
        {:noreply, %{state | waiters: state.waiters ++ [{from, topic, event, timer}]}}
    end
  end

  def handle_call(:close, _from, state) do
    _ = send_frame(state, {:close, 1000, ""})
    Mint.HTTP.close(state.conn)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_cast({:cast, topic, event, payload}, state) do
    {ref, state} = next_ref(state)

    message = %Message{
      join_ref: state.joins[topic],
      ref: ref,
      topic: topic,
      event: event,
      payload: payload
    }

    case send_message(state, message) do
      {:ok, state} -> {:noreply, state}
      {:error, state, reason} -> disconnect(state, reason)
    end
  end

  @impl true
  def handle_info({:reply_timeout, ref}, state) do
    case Map.pop(state.pending, ref) do
      {nil, _pending} ->
        {:noreply, state}

      {request, pending} ->
        Metrics.increment(state.metrics, request.metric <> ".errors")
        GenServer.reply(request.from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({:await_timeout, from}, state) do
    case List.keytake(state.waiters, from, 0) do
      {_waiter, waiters} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | waiters: waiters}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(:heartbeat, %{heartbeat_ref: nil} = state) do
    {ref, state} = next_ref(state)
    message = %Message{ref: ref, topic: "phoenix", event: "heartbeat", payload: %{}}

    case send_message(state, message) do
      {:ok, state} -> {:noreply, schedule_heartbeat(%{state | heartbeat_ref: ref})}
      {:error, state, reason} -> disconnect(state, reason)
    end
  end

  def handle_info(:heartbeat, state) do
    disconnect(state, :heartbeat_timeout)
  end

  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} -> handle_responses(responses, %{state | conn: conn})
      {:error, conn, reason, _responses} -> disconnect(%{state | conn: conn}, reason)
      :unknown -> {:noreply, state}
    end
  end

  defp connect(uri, path, opts) do
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
         {:ok, conn, status, headers} <- await_upgrade(conn, ref, deadline, nil, []),
         {:ok, conn, websocket} <- Mint.WebSocket.new(conn, ref, status, headers) do
      {:ok, conn, ref, websocket}
    else
      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_upgrade(conn, ref, deadline, status, headers) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            case upgrade_responses(responses, ref, status, headers) do
              {:done, status, headers} -> {:ok, conn, status, headers}
              {:more, status, headers} -> await_upgrade(conn, ref, deadline, status, headers)
            end

          {:error, conn, reason, _responses} ->
            {:error, conn, reason}

          :unknown ->
            await_upgrade(conn, ref, deadline, status, headers)
        end
    after
      timeout -> {:error, conn, %Mint.TransportError{reason: :timeout}}
    end
  end

  defp upgrade_responses(responses, ref, status, headers) do
    Enum.reduce(responses, {:more, status, headers}, fn
      {:status, ^ref, status}, {:more, _status, headers} -> {:more, status, headers}
      {:headers, ^ref, more}, {:more, status, headers} -> {:more, status, headers ++ more}
      {:done, ^ref}, {:more, status, headers} -> {:done, status, headers}
      _response, acc -> acc
    end)
  end

  defp handle_responses([{:data, ref, data} | responses], %{ref: ref} = state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        case handle_frames(frames, %{state | websocket: websocket}) do
          {:ok, state} -> handle_responses(responses, state)
          {:error, state, reason} -> disconnect(state, reason)
        end

      {:error, websocket, reason} ->
        disconnect(%{state | websocket: websocket}, reason)
    end
  end

  defp handle_responses([_response | responses], state), do: handle_responses(responses, state)
  defp handle_responses([], state), do: {:noreply, state}

  defp handle_frames([{:text, text} | frames], state) do
    case Serializer.decode(text, state.vsn) do
      {:ok, message} -> handle_frames(frames, handle_message(message, state))
      :error -> handle_frames(frames, state)
    end
  end

  defp handle_frames([{:ping, data} | frames], state) do
    with {:ok, state} <- send_frame(state, {:pong, data}) do
      handle_frames(frames, state)
    end
  end

  defp handle_frames([{:close, code, reason} | _frames], state) do
    {:error, state, {:remote_close, code, reason}}
  end

  defp handle_frames([{:error, reason} | _frames], state), do: {:error, state, reason}
  defp handle_frames([_frame | frames], state), do: handle_frames(frames, state)
  defp handle_frames([], state), do: {:ok, state}

  defp handle_message(%Message{event: "phx_reply", ref: ref} = message, state) do
    case Map.pop(state.pending, ref) do
      {nil, _pending} ->
        if ref == state.heartbeat_ref, do: %{state | heartbeat_ref: nil}, else: state

      {request, pending} ->
        resolve(request, message.payload, %{state | pending: pending})
    end
  end

  # Phoenix does not reply to pushes that were in flight when a channel
  # crashed or closed, so they fail now instead of waiting for their timeout.
  # Both messages carry the join ref of the channel they are about as `ref`.
  defp handle_message(%Message{event: event, topic: topic, ref: join_ref} = message, state)
       when event in ["phx_error", "phx_close"] and is_binary(join_ref) do
    reason = if event == "phx_error", do: :channel_crashed, else: :channel_closed

    {failed, pending} =
      Map.split_with(state.pending, fn {_ref, request} -> request.join_ref == join_ref end)

    for {_ref, request} <- failed do
      cancel_timer(request.timer)
      Metrics.increment(state.metrics, request.metric <> ".errors")
      GenServer.reply(request.from, {:error, reason})
    end

    joins =
      if state.joins[topic] == join_ref, do: Map.delete(state.joins, topic), else: state.joins

    Metrics.increment(state.metrics, "channel.messages")
    deliver(message, %{state | pending: pending, joins: joins})
  end

  defp handle_message(message, state) do
    Metrics.increment(state.metrics, "channel.messages")
    deliver(message, state)
  end

  defp send_request(state, message, from, kind, opts) do
    started_at = System.monotonic_time()

    case send_message(state, message) do
      {:ok, state} ->
        request = %{
          kind: kind,
          topic: message.topic,
          ref: message.ref,
          join_ref: message.join_ref,
          from: from,
          metric: opts[:metric],
          started_at: started_at,
          timer: start_timer({:reply_timeout, message.ref}, opts[:timeout])
        }

        {:noreply, %{state | pending: Map.put(state.pending, message.ref, request)}}

      {:error, state, reason} ->
        Metrics.increment(state.metrics, opts[:metric] <> ".errors")
        GenServer.reply(from, {:error, {:closed, reason}})
        disconnect(state, reason)
    end
  end

  defp resolve(request, payload, state) do
    cancel_timer(request.timer)
    result = reply_result(payload)

    case result do
      {:ok, _response} -> Metrics.record_since(state.metrics, request.metric, request.started_at)
      {:error, _response} -> Metrics.increment(state.metrics, request.metric <> ".errors")
    end

    GenServer.reply(request.from, result)
    track_join(state, request, result)
  end

  defp reply_result(%{"status" => "ok", "response" => response}), do: {:ok, response}
  defp reply_result(%{"response" => response}), do: {:error, response}
  defp reply_result(payload), do: {:error, payload}

  defp track_join(state, %{kind: :join, topic: topic, ref: ref}, {:ok, _response}) do
    %{state | joins: Map.put(state.joins, topic, ref)}
  end

  defp track_join(state, %{kind: kind, topic: topic}, _result) when kind in [:join, :leave] do
    %{state | joins: Map.delete(state.joins, topic)}
  end

  defp track_join(state, _request, _result), do: state

  defp deliver(%Message{topic: topic, event: event} = message, state) do
    case Enum.split_while(state.waiters, &(not waiting_for?(&1, topic, event))) do
      {before, [{from, _topic, _event, timer} | rest]} ->
        cancel_timer(timer)
        GenServer.reply(from, {:ok, message.payload})
        %{state | waiters: before ++ rest}

      {_waiters, []} ->
        enqueue(state, message)
    end
  end

  defp waiting_for?({_from, topic, event, _timer}, topic, event), do: true
  defp waiting_for?(_waiter, _topic, _event), do: false

  defp enqueue(%{inbox_size: @inbox_limit} = state, message) do
    Metrics.increment(state.metrics, "channel.messages.dropped")
    %{state | inbox: :queue.in(message, :queue.drop(state.inbox))}
  end

  defp enqueue(state, message) do
    %{state | inbox: :queue.in(message, state.inbox), inbox_size: state.inbox_size + 1}
  end

  defp take_message(state, topic, event) do
    messages = :queue.to_list(state.inbox)

    case Enum.split_while(messages, &(not match?(%Message{topic: ^topic, event: ^event}, &1))) do
      {before, [message | rest]} ->
        inbox = :queue.from_list(before ++ rest)
        {:ok, message, %{state | inbox: inbox, inbox_size: state.inbox_size - 1}}

      {_messages, []} ->
        :error
    end
  end

  defp disconnect(state, reason) do
    Metrics.increment(state.metrics, "ws.disconnects")

    for {_ref, request} <- state.pending do
      Metrics.increment(state.metrics, request.metric <> ".errors")
      GenServer.reply(request.from, {:error, {:closed, reason}})
    end

    for {from, _topic, _event, _timer} <- state.waiters do
      GenServer.reply(from, {:error, {:closed, reason}})
    end

    Mint.HTTP.close(state.conn)
    {:stop, :normal, %{state | pending: %{}, waiters: []}}
  end

  defp send_message(state, message) do
    send_frame(state, {:text, Serializer.encode(message, state.vsn)})
  end

  defp send_frame(state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         state = %{state | websocket: websocket},
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      {:ok, %{state | conn: conn}}
    else
      {:error, %Mint.WebSocket{} = websocket, reason} ->
        {:error, %{state | websocket: websocket}, reason}

      {:error, conn, reason} ->
        {:error, %{state | conn: conn}, reason}
    end
  end

  defp next_ref(state) do
    ref = state.next_ref + 1
    {Integer.to_string(ref), %{state | next_ref: ref}}
  end

  defp schedule_heartbeat(%{heartbeat_interval: nil} = state), do: state

  defp schedule_heartbeat(state) do
    Process.send_after(self(), :heartbeat, state.heartbeat_interval)
    state
  end

  defp start_timer(_message, :infinity), do: nil
  defp start_timer(message, timeout), do: Process.send_after(self(), message, timeout)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer, async: true, info: false)
end
