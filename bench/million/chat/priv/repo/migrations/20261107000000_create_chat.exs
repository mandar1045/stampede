defmodule Chat.Repo.Migrations.CreateChat do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :name, :text, null: false
    end

    create table(:rooms) do
      add :name, :text, null: false
    end

    create table(:messages) do
      add :room_id, references(:rooms), null: false
      add :user_id, references(:users), null: false
      add :body, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    # The latest messages in a room, and the pages before them.
    create index(:messages, [:room_id, :id])
    create index(:messages, [:user_id])

    create table(:room_reads, primary_key: false) do
      add :user_id, references(:users), primary_key: true
      add :room_id, references(:rooms), primary_key: true
      add :last_read_id, :bigint, null: false
    end
  end
end
