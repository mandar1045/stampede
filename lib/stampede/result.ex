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
      ends at (`:at`, in milliseconds), the number of busy `:vus`, the
      `:metrics` of that second alone, and how `:busy` the load test's
      schedulers were, from 0 to 1, on its busiest node. Above 0.9, the load
      test's own delays show up in its timings, and the summary says so.
    * `:thresholds` - one map per limit, with `:metric`, `:stat`, `:limit`,
      the `:value` it had and whether it `:passed?`
    * `:errors` - the iterations that failed, grouped by kind of error, with a
      `:message` and a `:count`, most frequent first
    * `:passed?` - whether every threshold passed, or for a run with
      `:find_limit`, whether it found a limit, at least `:min` if given
    * `:limit` - for a run with `:find_limit`, what it found: the highest
      load that passed as `:value`, `:by` (`:vus` or `:rate`), the step that
      failed as `:failed`, whether it got `:up_to?` the most it was asked to
      try without failing, and every step checked as `:steps`. Each step has
      its `:target`, the `:from` and `:to` of the step, ramp included, in
      milliseconds, the `:metrics` and `:thresholds` of that time, whether
      it `:passed?`, and how `:busy` the load test and the server
      (`:server_busy`, with `:probe`) were at most, from 0 to 1. `nil` for
      other runs.
    * `:server` - for a run with `:probe`, what the application's nodes
      looked like at their peak: the `:nodes`, how `:busy` their schedulers
      were, from 0 to 1, their `:memory` in bytes, their `:processes`, their
      `:run_queue`, and the longest message `:queues` seen. `nil` for other
      runs. Each second in the `:timeline` also has a `:server` with those
      numbers.

  Rates are per second.
  """

  defstruct [
    :scenario,
    :duration,
    metrics: %{},
    timeline: [],
    thresholds: [],
    errors: [],
    passed?: true,
    limit: nil,
    server: nil
  ]

  @type t :: %__MODULE__{
          scenario: module(),
          duration: non_neg_integer(),
          metrics: %{optional(String.t()) => map()},
          timeline: [
            %{
              required(:at) => non_neg_integer(),
              required(:vus) => non_neg_integer(),
              required(:busy) => float(),
              required(:metrics) => map(),
              optional(:server) => map()
            }
          ],
          thresholds: [map()],
          errors: [%{message: String.t(), count: pos_integer()}],
          passed?: boolean(),
          limit: map() | nil,
          server: map() | nil
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
