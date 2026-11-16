defmodule Chat.Fanout do
  @moduledoc """
  How a new message reaches the people in its room, picked with `FANOUT`, to
  compare the ways suggested for cutting the cost of fan-out:

    * `broadcast` - the default, and what the 40,000 run used. One broadcast
      of the whole message, which Phoenix encodes once and writes to every
      socket in the room
    * `ids` - the message goes into ETS and only its id is broadcast. Each
      channel process reads the message back and pushes it, which also means
      each one encodes it
    * `batch` - a process per room collects messages for `FANOUT_WINDOW`
      milliseconds, 500 by default, and broadcasts them together as
      `new_msgs`. Fewer broadcasts, but each message waits for its window
  """

  use Supervisor

  alias ChatWeb.Endpoint

  @table __MODULE__
  # The ETS table is a ring, so it stays the same size however long the run.
  # At 1,000 messages a second, a message stays readable for over 15 minutes.
  @slots 1_000_000

  def mode, do: Application.get_env(:chat, :fanout, "broadcast")

  def start_link(_opts), do: Supervisor.start_link(__MODULE__, mode(), name: __MODULE__)

  @impl true
  def init("broadcast"), do: :ignore

  def init("ids") do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    # The table belongs to this supervisor, which runs as long as the app does.
    Supervisor.init([], strategy: :one_for_one)
  end

  def init("batch") do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: Chat.Fanout.Rooms},
        {DynamicSupervisor, name: Chat.Fanout.Batchers, strategy: :one_for_one}
      ],
      strategy: :one_for_one
    )
  end

  def init(other), do: raise(ArgumentError, "unknown FANOUT #{inspect(other)}")

  @doc "Sends `message` to everyone in `room_id`, the way `mode/0` says."
  def deliver(room_id, message), do: deliver(mode(), room_id, message)

  defp deliver("broadcast", room_id, message),
    do: Endpoint.broadcast!(topic(room_id), "new_msg", message)

  defp deliver("ids", room_id, message) do
    :ets.insert(@table, {rem(message.id, @slots), message.id, message})
    Endpoint.broadcast!(topic(room_id), "new_msg_id", %{id: message.id})
  end

  defp deliver("batch", room_id, message), do: send(batcher(room_id), {:message, message})

  @doc "Reads back a message `deliver/2` put in ETS, or `nil` once the ring wrapped past it."
  def lookup(id) do
    case :ets.lookup(@table, rem(id, @slots)) do
      [{_slot, ^id, message}] -> message
      _gone -> nil
    end
  end

  defp batcher(room_id) do
    case Registry.lookup(Chat.Fanout.Rooms, room_id) do
      [{pid, _value}] ->
        pid

      [] ->
        spec = {Chat.Fanout.Batcher, room_id}

        case DynamicSupervisor.start_child(Chat.Fanout.Batchers, spec) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  def topic(room_id), do: "room:#{room_id}"
end

defmodule Chat.Fanout.Batcher do
  @moduledoc false

  # Collects one room's messages and broadcasts them together, a window after
  # the first one arrived.

  use GenServer, restart: :transient

  def start_link(room_id) do
    name = {:via, Registry, {Chat.Fanout.Rooms, room_id}}
    GenServer.start_link(__MODULE__, room_id, name: name)
  end

  @impl true
  def init(room_id) do
    {:ok,
     %{room_id: room_id, messages: [], window: Application.get_env(:chat, :fanout_window, 500)}}
  end

  @impl true
  def handle_info({:message, message}, %{messages: []} = state) do
    Process.send_after(self(), :flush, state.window)
    {:noreply, %{state | messages: [message]}}
  end

  def handle_info({:message, message}, state) do
    {:noreply, %{state | messages: [message | state.messages]}}
  end

  def handle_info(:flush, state) do
    ChatWeb.Endpoint.broadcast!(Chat.Fanout.topic(state.room_id), "new_msgs", %{
      messages: Enum.reverse(state.messages)
    })

    {:noreply, %{state | messages: []}}
  end
end
