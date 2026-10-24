defmodule Stampede.ExUnit do
  @moduledoc """
  Assertions to run load tests as part of a test suite.

      # Scenarios in loadtest/ are scripts, which are not compiled with
      # the app, so they are loaded first.
      Code.require_file("../loadtest/lobby.exs", __DIR__)
      Code.require_file("../loadtest/chat.exs", __DIR__)

      defmodule MyApp.LoadTest do
        use ExUnit.Case
        import Stampede.ExUnit

        # Load tests take a while, so they only run when asked for.
        @moduletag :load

        test "the lobby holds 200 users" do
          assert_load(MyApp.Load.Lobby, vus: 200, duration: [second: 30])
        end

        test "every message reaches the room" do
          result = assert_load(MyApp.Load.Chat, vus: 50, duration: [second: 30])
          assert result.metrics["chat.received"].count >= result.metrics["chat.sent"].count
        end
      end

  A test fails when a threshold of the run fails, with the summary of the run
  in its message. A run with no thresholds always passes, so give each
  scenario the limits it must stay within, such as
  `{"iteration.errors", count: 0}`.

  ## Running them

  Leave load tests out of the usual `mix test` in `test/test_helper.exs`:

      ExUnit.start(exclude: [:load])

  and run them with `mix test --only load`.

  Run the app being tested as a server of its own, such as with
  `mix phx.server`, and point the scenarios at it. Inside `mix test`, the
  Ecto SQL sandbox sends every query through one connection, so a load test
  against the test server would mostly measure the sandbox. The
  [CI guide](ci.md) starts the server before the load tests.
  """

  alias Stampede.{Reporter, Result}

  # ExUnit is only loaded in tests, which is the only place these run.
  @compile {:no_warn_undefined, ExUnit.AssertionError}

  @doc """
  Runs `scenario` with `opts`, as `Stampede.run/2` does, and fails the test
  if any of its thresholds failed.

  Returns the `Stampede.Result`, for further assertions.
  """
  @spec assert_load(module(), keyword()) :: Result.t()
  def assert_load(scenario, opts \\ []) when is_atom(scenario) and is_list(opts) do
    scenario
    |> Stampede.run(opts)
    |> assert_passed()
  end

  @doc """
  Fails the test if any threshold of `result` failed, and returns `result`
  otherwise.

  Useful with `Stampede.run_parallel/2`:

      for result <- Stampede.run_parallel([Reading, Posting]), do: assert_passed(result)
  """
  @spec assert_passed(Result.t()) :: Result.t()
  def assert_passed(%Result{passed?: true} = result), do: result

  def assert_passed(%Result{} = result) do
    failed = Enum.count(result.thresholds, &(not &1.passed?))
    count = length(result.thresholds)
    thresholds = if count == 1, do: "threshold", else: "thresholds"

    raise ExUnit.AssertionError,
      message:
        "#{inspect(result.scenario)} failed #{failed} of #{count} #{thresholds}\n\n" <>
          Reporter.format(result)
  end
end
