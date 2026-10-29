defmodule MillionWeb.UserSocket do
  use Phoenix.Socket

  channel "room:*", MillionWeb.RoomChannel

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
