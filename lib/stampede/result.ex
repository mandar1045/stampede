defmodule Stampede.Result do
  @moduledoc """
  The outcome of `Stampede.run/2`.

    * `:scenario` - the scenario that ran
    * `:duration` - how long it ran, in milliseconds
    * `:metrics` - a map from each metric's name to its summary. Timings have
      `:count`, `:rate`, `:min`, `:mean`, `:p50`, `:p90`, `:p95`, `:p99` and
      `:max`, with times in milliseconds, and `type: :timing`. Counters have
      `:count`, `:rate` and `type: :counter`.
    * `:thresholds` - one map per limit, with `:metric`, `:stat`, `:limit`,
      the `:value` it had and whether it `:passed?`
    * `:errors` - the iterations that failed, grouped by kind of error, with a
      `:message` and a `:count`, most frequent first
    * `:passed?` - whether every threshold passed
  """

  defstruct [:scenario, :duration, metrics: %{}, thresholds: [], errors: [], passed?: true]

  @type t :: %__MODULE__{
          scenario: module(),
          duration: non_neg_integer(),
          metrics: %{optional(String.t()) => map()},
          thresholds: [map()],
          errors: [%{message: String.t(), count: pos_integer()}],
          passed?: boolean()
        }

  @doc false
  def new(scenario, duration, summary, thresholds) do
    %__MODULE__{
      scenario: scenario,
      duration: duration,
      metrics: summary.metrics,
      errors: summary.errors,
      thresholds: thresholds,
      passed?: Enum.all?(thresholds, & &1.passed?)
    }
  end
end
