defmodule Stampede.Limit do
  @moduledoc false

  # Finds the most load a scenario's thresholds allow. The load goes up a
  # step at a time, each step ramps then holds, and the thresholds are
  # checked over each whole step. The ramp counts too, since that's when
  # VUs that connect once and stay, connect. The run ends at the first step
  # that fails, or after the last one.

  alias Stampede.{Metrics, Plan, Thresholds}

  defstruct [
    :by,
    :targets,
    :ramp,
    :hold,
    :min,
    :thresholds,
    index: 0,
    rows: %{},
    busy: 0.0,
    server_busy: 0.0,
    server_lost?: false,
    steps: []
  ]

  @defaults [
    by: :vus,
    start: nil,
    step: 50,
    up_to: 10_000,
    ramp: [second: 5],
    hold: [second: 30],
    min: nil
  ]

  # A second may run a few milliseconds past the step it belongs to.
  @slack 100

  def new!(true, thresholds), do: new!([], thresholds)

  def new!(opts, thresholds) when is_list(opts) do
    opts = Keyword.validate!(opts, @defaults)

    if thresholds == [] do
      raise ArgumentError,
            "expected :thresholds to be given with :find_limit, since they decide " <>
              "when the load is too much, such as [{\"channel.join\", p95: 500}]"
    end

    by = by!(opts[:by])
    step = amount!(:step, opts[:step], by)
    start = amount!(:start, opts[:start] || step, by)
    up_to = amount!(:up_to, opts[:up_to], by)

    if up_to < start do
      raise ArgumentError, "expected :up_to to be at least :start, got: #{up_to} < #{start}"
    end

    hold = Plan.milliseconds!(opts[:hold])

    if hold < 2_000 do
      raise ArgumentError,
            "expected :hold to be at least 2 seconds, so each step has samples to check"
    end

    %__MODULE__{
      by: by,
      targets: start |> Stream.iterate(&(&1 + step)) |> Enum.take_while(&(&1 <= up_to)),
      ramp: Plan.milliseconds!(opts[:ramp]),
      hold: hold,
      min: opts[:min],
      thresholds: thresholds
    }
  end

  def new!(other, _thresholds) do
    raise ArgumentError,
          "expected :find_limit to be true or a keyword list, got: #{inspect(other)}"
  end

  # The stages of the run, each target ramped to and then held.
  def plan_options(%__MODULE__{} = limit) do
    stages = Enum.flat_map(limit.targets, &[{limit.ramp, &1}, {limit.hold, &1}])

    case limit.by do
      :vus -> [stages: stages, rate: nil, rate_stages: nil]
      :rate -> [rate_stages: stages, stages: nil, rate: nil]
    end
  end

  # Takes the counts of the second that ended `to` milliseconds into the run,
  # which belong to the step it ends in, and how busy the load test and the
  # server were, and whether the server went down. Returns {:stop, limit} once
  # a step failed or the last one passed.
  def add_second(%__MODULE__{} = limit, to, rows, busy, server_busy, server_lost?) do
    {_step_from, step_to} = window(limit, limit.index)

    limit = %{
      limit
      | rows: Map.merge(limit.rows, rows, fn _key, a, b -> a + b end),
        busy: max(limit.busy, busy),
        server_busy: max(limit.server_busy, server_busy),
        server_lost?: limit.server_lost? or server_lost?
    }

    if to >= step_to - @slack, do: check(limit), else: {:continue, limit}
  end

  defp check(limit) do
    {from, to} = window(limit, limit.index)
    summary = Metrics.summary(limit.rows, to - from)
    thresholds = Thresholds.evaluate(limit.thresholds, summary.metrics)

    step = %{
      target: Enum.at(limit.targets, limit.index),
      from: from,
      to: to,
      metrics: summary.metrics,
      thresholds: thresholds,
      passed?: Enum.all?(thresholds, & &1.passed?),
      busy: limit.busy,
      server_busy: limit.server_busy,
      server_lost?: limit.server_lost?
    }

    limit = %{
      limit
      | steps: [step | limit.steps],
        index: limit.index + 1,
        rows: %{},
        busy: 0.0,
        server_busy: 0.0
    }

    if step.passed? and limit.index < length(limit.targets),
      do: {:continue, limit},
      else: {:stop, limit}
  end

  defp window(limit, index) do
    from = index * (limit.ramp + limit.hold)
    {from, from + limit.ramp + limit.hold}
  end

  # What the run found: the highest target that passed, the step that failed
  # if any, and every step checked.
  def summary(%__MODULE__{} = limit) do
    steps = Enum.reverse(limit.steps)
    {passed, failed} = Enum.split_while(steps, & &1.passed?)
    value = if passed == [], do: nil, else: List.last(passed).target

    %{
      by: limit.by,
      value: value,
      failed: List.first(failed),
      up_to?: failed == [] and length(steps) == length(limit.targets),
      min: limit.min,
      steps: steps
    }
  end

  def passed?(%{value: nil}), do: false
  def passed?(%{min: nil}), do: true
  def passed?(%{value: value, min: min}), do: value >= min

  defp by!(by) when by in [:vus, :rate], do: by

  defp by!(other) do
    raise ArgumentError, "expected :by to be :vus or :rate, got: #{inspect(other)}"
  end

  defp amount!(_name, value, :vus) when is_integer(value) and value > 0, do: value
  defp amount!(_name, value, :rate) when is_number(value) and value > 0, do: value

  defp amount!(name, value, by) do
    kind = if by == :vus, do: "a positive integer", else: "a positive number"
    raise ArgumentError, "expected #{inspect(name)} to be #{kind}, got: #{inspect(value)}"
  end
end
