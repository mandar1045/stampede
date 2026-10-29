defmodule Stampede.WebSocket.Client do
  @moduledoc false

  use GenServer

  alias Stampede.Metrics
  alias Stampede.WebSocket.Connection

  @inbox_limit 1_000

  # Hibernates while idle, like `Stampede.Channels.Socket`.
  @hibernate_after 5_000

  # Once the connection closes, `closed` holds why, and the process stays
  # around so that frames received before the close can still be read.
  defstruct [
    :conn,
    :ref,
    :websocket,
    :metrics,
    :closed,
    waiters: [],
    inbox: :queue.new(),
    inbox_size: 0
  ]

  def start_link(uri, path, opts) do
    GenServer.start_link(__MODULE__, {uri, path, opts, Metrics.current()},
      hibernate_after: @hibernate_after
    )
  end

  def request(client, request) do
    GenServer.call(client, request, :infinity)
  catch
    :exit, _reason -> {:error, :closed}
  end

  @impl true
  def init({uri, path, opts, metrics}) do
    started_at = System.monotonic_time()

    case Connection.connect(uri, path, opts) do
      {:ok, conn, ref, websocket, frames} ->
        Metrics.record_since(metrics, "ws.connect", started_at)
        state = %__MODULE__{conn: conn, ref: ref, websocket: websocket, metrics: metrics}
        {:ok, handle_frames(frames, state)}

      {:error, reason} ->
        Metrics.increment(metrics, "ws.connect.errors")
        {:error, reason}
    end
  end

  @impl true
  def handle_call({:send, _frame}, _from, %{closed: closed} = state) when closed != nil do
    {:reply, {:error, {:closed, closed}}, state}
  end

  def handle_call({:send, frame}, _from, state) do
    case send_frame(state, frame) do
      {:ok, state} ->
        Metrics.increment(state.metrics, "ws.messages.sent")
        {:reply, :ok, state}

      {:error, state, reason} ->
        {:reply, {:error, {:closed, reason}}, disconnect(state, reason)}
    end
  end

  def handle_call({:await, match, timeout}, from, state) do
    case take_frame(state, match) do
      {:ok, frame, state} ->
        {:reply, {:ok, frame}, state}

      :error when state.closed != nil ->
        {:reply, {:error, {:closed, state.closed}}, state}

      :error ->
        timer = start_timer({:await_timeout, from}, timeout)
        {:noreply, %{state | waiters: state.waiters ++ [{from, match, timer}]}}
    end
  end

  def handle_call(:close, _from, state) do
    if state.closed == nil do
      _ = send_frame(state, {:close, 1000, ""})
      Mint.HTTP.close(state.conn)
    end

    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({:await_timeout, from}, state) do
    case List.keytake(state.waiters, from, 0) do
      {_waiter, waiters} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | waiters: waiters}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_message, %{closed: closed} = state) when closed != nil do
    {:noreply, state}
  end

  def handle_info(message, state) do
    case Connection.stream(state.conn, state.ref, state.websocket, message) do
      {:ok, conn, websocket, frames} ->
        {:noreply, handle_frames(frames, %{state | conn: conn, websocket: websocket})}

      {:error, conn, websocket, reason} ->
        {:noreply, disconnect(%{state | conn: conn, websocket: websocket}, reason)}

      :unknown ->
        {:noreply, state}
    end
  end

  defp handle_frames([{type, _data} = frame | frames], state) when type in [:text, :binary] do
    Metrics.increment(state.metrics, "ws.messages")
    handle_frames(frames, deliver(state, frame))
  end

  defp handle_frames([{:ping, data} | frames], state) do
    case send_frame(state, {:pong, data}) do
      {:ok, state} -> handle_frames(frames, state)
      {:error, state, reason} -> disconnect(state, reason)
    end
  end

  defp handle_frames([{:close, code, reason} | _frames], state) do
    _ = send_frame(state, {:close, 1000, ""})
    disconnect(state, {:remote_close, code, reason})
  end

  defp handle_frames([{:error, reason} | _frames], state), do: disconnect(state, reason)
  defp handle_frames([_frame | frames], state), do: handle_frames(frames, state)
  defp handle_frames([], state), do: state

  defp deliver(state, frame) do
    case Enum.split_while(state.waiters, fn {_from, match, _timer} ->
           not matches?(match, frame)
         end) do
      {before, [{from, _match, timer} | rest]} ->
        cancel_timer(timer)
        GenServer.reply(from, {:ok, frame})
        %{state | waiters: before ++ rest}

      {_waiters, []} ->
        enqueue(state, frame)
    end
  end

  # A match function that raises is treated as no match, rather than taking
  # the connection down with it.
  defp matches?(nil, _frame), do: true

  defp matches?(match, frame) do
    match.(frame) not in [nil, false]
  rescue
    _error -> false
  end

  defp enqueue(%{inbox_size: @inbox_limit} = state, frame) do
    Metrics.increment(state.metrics, "ws.messages.dropped")
    %{state | inbox: :queue.in(frame, :queue.drop(state.inbox))}
  end

  defp enqueue(state, frame) do
    %{state | inbox: :queue.in(frame, state.inbox), inbox_size: state.inbox_size + 1}
  end

  defp take_frame(state, match) do
    case Enum.split_while(:queue.to_list(state.inbox), &(not matches?(match, &1))) do
      {before, [frame | rest]} ->
        inbox = :queue.from_list(before ++ rest)
        {:ok, frame, %{state | inbox: inbox, inbox_size: state.inbox_size - 1}}

      {_frames, []} ->
        :error
    end
  end

  defp disconnect(state, reason) do
    Metrics.increment(state.metrics, "ws.disconnects")

    for {from, _match, timer} <- state.waiters do
      cancel_timer(timer)
      GenServer.reply(from, {:error, {:closed, reason}})
    end

    Mint.HTTP.close(state.conn)
    %{state | closed: reason, waiters: []}
  end

  defp send_frame(state, frame) do
    case Connection.send_frame(state.conn, state.ref, state.websocket, frame) do
      {:ok, conn, websocket} ->
        {:ok, %{state | conn: conn, websocket: websocket}}

      {:error, conn, websocket, reason} ->
        {:error, %{state | conn: conn, websocket: websocket}, reason}
    end
  end

  defp start_timer(_message, :infinity), do: nil
  defp start_timer(message, timeout), do: Process.send_after(self(), message, timeout)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer, async: true, info: false)
end
