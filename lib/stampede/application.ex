defmodule Stampede.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Livebook lists the smart cell once it's registered. It's only there
    # when Kino is, so it's called by a name only known when the app runs.
    smart_cell = Stampede.Kino.SmartCell
    if Code.ensure_loaded?(smart_cell), do: smart_cell.register()

    Supervisor.start_link([Stampede.Address], strategy: :one_for_one, name: Stampede.Supervisor)
  end
end
