defmodule Stampede.Result do
  @moduledoc """
  The outcome of `Stampede.run/2`.

    * `:scenario` - the scenario that ran
    * `:duration` - how long it ran, in milliseconds
    * `:metrics` - a map from each metric's name to its summary:
      * timings have `type: :timing`, `:count`, `:rate`, `:min`, `:mean`,
        `:p50`, `:p90`, `:p95`, `:p99` and `:max`, with times in milliseconds
      * counters have `type: :counter`, `:count` and `:rate`
      * checks have `type: :check`, `:count`, `:rate`, `:passed`, `:failed`
        and `:failed_rate`, the share of checks that failed
    * `:timeline` - one point per second of the run, each with the time it
      ends at (`:at`, in milliseconds), the number of busy `:vus`, and the
      `:metrics` of that second alone
    * `:thresholds` - one map per limit, with `:metric`, `:stat`, `:limit`,
      the `:value` it had and whether it `:passed?`
    * `:errors` - the iterations that failed, grouped by kind of error, with a
      `:message` and a `:count`, most frequent first
    * `:passed?` - whether every threshold passed

  Rates are per second.
  """

  defstruct [
    :scenario,
    :duration,
    metrics: %{},
    timeline: [],
    thresholds: [],
    errors: [],
    passed?: true
  ]

  @type t :: %__MODULE__{
          scenario: module(),
          duration: non_neg_integer(),
          metrics: %{optional(String.t()) => map()},
          timeline: [%{at: non_neg_integer(), vus: non_neg_integer(), metrics: map()}],
          thresholds: [map()],
          errors: [%{message: String.t(), count: pos_integer()}],
          passed?: boolean()
        }

  @doc false
  def new(scenario, duration, summary, thresholds, timeline \\ []) do
    %__MODULE__{
      scenario: scenario,
      duration: duration,
      metrics: summary.metrics,
      timeline: timeline,
      errors: summary.errors,
      thresholds: thresholds,
      passed?: Enum.all?(thresholds, & &1.passed?)
    }
  end
end
