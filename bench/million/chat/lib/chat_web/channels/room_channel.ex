defmodule ChatWeb.RoomChannel do
  use Phoenix.Channel

  alias Chat.Messages

  # Joining loads the latest messages and marks them read, like opening a chat.
  @impl true
  def join("room:" <> room, _payload, socket) do
    room_id = String.to_integer(room)
    messages = Messages.latest(room_id)

    if last = List.first(messages),
      do: Messages.mark_read(socket.assigns.user_id, room_id, last.id)

    {:ok, %{messages: messages}, assign(socket, :room_id, room_id)}
  end

  # Sending writes the message, then broadcasts it to the room.
  @impl true
  def handle_in("new_msg", %{"body" => body}, socket) do
    message = Messages.create!(socket.assigns.room_id, socket.assigns.user_id, body)
    broadcast!(socket, "new_msg", message)
    {:reply, {:ok, %{id: message.id}}, socket}
  end

  # Scrolling up loads the page of messages before the oldest one shown.
  def handle_in("history", %{"before" => before}, socket) do
    {:reply, {:ok, %{messages: Messages.before(socket.assigns.room_id, before)}}, socket}
  end
end
