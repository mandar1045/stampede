defmodule ChatWeb.RoomChannel do
  use Phoenix.Channel

  alias Chat.{Fanout, Messages}

  # Only broadcast with FANOUT=ids. Intercepting it is what lets each channel
  # read the message back, and what takes it off Phoenix's encode-once path.
  intercept ["new_msg_id"]

  # Joining loads the latest messages and marks them read, like opening a chat.
  @impl true
  def join("room:" <> room, _payload, socket) do
    room_id = String.to_integer(room)
    messages = Messages.latest(room_id)

    if last = List.first(messages),
      do: Messages.mark_read(socket.assigns.user_id, room_id, last.id)

    {:ok, %{messages: messages}, assign(socket, :room_id, room_id)}
  end

  # Sending writes the message, then sends it to the room, as Chat.Fanout says.
  @impl true
  def handle_in("new_msg", %{"body" => body}, socket) do
    message = Messages.create!(socket.assigns.room_id, socket.assigns.user_id, body)
    Fanout.deliver(socket.assigns.room_id, message)
    {:reply, {:ok, %{id: message.id}}, socket}
  end

  # Scrolling up loads the page of messages before the oldest one shown.
  def handle_in("history", %{"before" => before}, socket) do
    {:reply, {:ok, %{messages: Messages.before(socket.assigns.room_id, before)}}, socket}
  end

  @impl true
  def handle_out("new_msg_id", %{id: id}, socket) do
    if message = Fanout.lookup(id), do: push(socket, "new_msg", message)
    {:noreply, socket}
  end
end
