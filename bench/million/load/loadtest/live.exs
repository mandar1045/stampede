defmodule Load.Live do
  @moduledoc """
  People on a LiveView page: each one loads `/counter`, connects and stays,
  clicking the button every `PAUSE` seconds.
  """

  use Stampede.Scenario

  @impl true
  def options do
    Load.options([
      {"live.join", p95: 1_000},
      {"live.event", p95: 1_000},
      {"iteration.errors", count: 0}
    ])
  end

  @impl true
  def run(vu) do
    {:ok, view} =
      Stampede.LiveView.connect(Load.url("http", "/counter"),
        transport_opts: Load.transport_opts(vu),
        timeout: 30_000
      )

    click(view)
  end

  defp click(view) do
    Load.pause()
    {:ok, _reply} = Stampede.LiveView.click(view, "inc")
    click(view)
  end
end
