defmodule MillionWeb.CounterLive do
  use MillionWeb, :live_view

  def mount(_params, _session, socket), do: {:ok, assign(socket, count: 0)}

  def render(assigns) do
    ~H"""
    <p>Count: {@count}</p>
    <button phx-click="inc">+1</button>
    """
  end

  def handle_event("inc", _params, socket), do: {:noreply, update(socket, :count, &(&1 + 1))}
end
