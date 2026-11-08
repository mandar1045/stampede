defmodule Chat.Messages do
  @moduledoc "Chat messages, read and written the way a chat app does."

  import Ecto.Query
  alias Chat.Repo

  @page 50

  def latest(room_id) do
    page(from(m in "messages", where: m.room_id == ^room_id))
  end

  def before(room_id, before_id) do
    page(from(m in "messages", where: m.room_id == ^room_id and m.id < ^before_id))
  end

  defp page(query) do
    from(m in query,
      join: u in "users",
      on: u.id == m.user_id,
      order_by: [desc: m.id],
      limit: @page,
      select: %{id: m.id, body: m.body, user: u.name, at: m.inserted_at}
    )
    |> Repo.all()
  end

  def create!(room_id, user_id, body) do
    now = DateTime.utc_now()

    {1, [%{id: id}]} =
      Repo.insert_all(
        "messages",
        [%{room_id: room_id, user_id: user_id, body: body, inserted_at: now}],
        returning: [:id]
      )

    %{id: id, body: body, user_id: user_id, at: now}
  end

  def mark_read(user_id, room_id, message_id) do
    Repo.insert_all(
      "room_reads",
      [%{user_id: user_id, room_id: room_id, last_read_id: message_id}],
      on_conflict: [set: [last_read_id: message_id]],
      conflict_target: [:user_id, :room_id]
    )
  end
end
