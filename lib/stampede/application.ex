defmodule Stampede.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([Stampede.Address], strategy: :one_for_one, name: Stampede.Supervisor)
  end
end
