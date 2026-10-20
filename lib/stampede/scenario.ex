defmodule Stampede.Scenario do
  @moduledoc """
  The behaviour of a load test.

  Only `c:run/1` is required:

      defmodule MyApp.Load.Home do
        use Stampede.Scenario

        @impl true
        def options, do: [vus: 10, duration: [minute: 1]]

        @impl true
        def run(_vu) do
          {:ok, socket} = Stampede.Channels.connect("ws://localhost:4000/socket")
          {:ok, _reply} = Stampede.Channels.join(socket, "home")
          Process.sleep(500)
        end
      end

  `use Stampede.Scenario` declares the behaviour and nothing else.
  """

  @doc """
  Returns the default options of the scenario. See `Stampede.run/2`.
  """
  @callback options() :: keyword()

  @doc """
  Runs once before the first VU starts, in the process that called
  `Stampede.run/2`.

  It receives the options of the run, and what it returns is given to every
  VU as `vu.data`. Use it for work that should not be repeated, such as
  creating accounts or signing tokens.
  """
  @callback setup(opts :: keyword()) :: term()

  @doc """
  Runs one iteration of a VU.

  Stampede calls it again as soon as it returns, until the VU is stopped.
  Sockets opened with `Stampede.Channels.connect/2` during an iteration are
  closed when it returns, so a VU that should stay connected for the whole
  test must keep `run/1` from returning, for example with a loop.

  If `run/1` raises, throws or exits, the error is counted under
  `"iteration.errors"` and the VU waits 100ms before its next iteration, so a
  failing scenario does not spin.
  """
  @callback run(vu :: Stampede.VU.t()) :: term()

  @optional_callbacks options: 0, setup: 1

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour Stampede.Scenario
    end
  end
end
