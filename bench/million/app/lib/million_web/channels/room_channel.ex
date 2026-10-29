defmodule MillionWeb.RoomChannel do
  use Phoenix.Channel

  @impl true
  def join("room:" <> _name, _payload, socket), do: {:ok, socket}

  @impl true
  def handle_in("ping", payload, socket), do: {:reply, {:ok, payload}, socket}
end
