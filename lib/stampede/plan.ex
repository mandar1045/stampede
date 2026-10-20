defmodule Stampede.Plan do
  @moduledoc false

  # A plan either keeps a number of VUs running (`:vus`), or starts iterations
  # at a rate, in iterations per second (`:rate`). Either way, its stages move
  # the target in a straight line from one value to the next.
  defstruct [:mode, :stages, :max_vus]

  def from_options(opts) do
    given = Enum.reject(Keyword.take(opts, [:stages, :rate, :rate_stages]), &is_nil(elem(&1, 1)))

    case given do
      [] ->
        plan(:vus, constant(Keyword.fetch!(opts, :vus), opts[:duration]), opts)

      [stages: stages] ->
        plan(:vus, stages, opts)

      [rate: rate] ->
        plan(:rate, constant(rate, opts[:duration]), opts)

      [rate_stages: stages] ->
        plan(:rate, stages, opts)

      _many ->
        raise ArgumentError, "expected only one of :stages, :rate and :rate_stages to be given"
    end
  end

  def duration(%__MODULE__{stages: stages}) do
    stages |> Enum.map(&elem(&1, 0)) |> Enum.sum()
  end

  # The target at `elapsed` milliseconds: VUs, or iterations per second.
  def target_at(%__MODULE__{stages: stages}, elapsed), do: target_at(stages, elapsed, 0)

  defp target_at([{duration, target} | stages], elapsed, _from) when elapsed >= duration do
    target_at(stages, elapsed - duration, target)
  end

  defp target_at([{duration, target} | _stages], elapsed, from) do
    from + (target - from) * elapsed / duration
  end

  defp target_at([], _elapsed, from), do: from

  # How many iterations a rate plan has started by `elapsed` milliseconds: the
  # area under its rate, which is exact since every stage is a straight line.
  # Rounding up starts the first iteration right away, so a constant rate
  # starts exactly `rate * duration` iterations.
  def started_by(%__MODULE__{mode: :rate, stages: stages}, elapsed) do
    ceil(area(stages, elapsed, 0, 0.0))
  end

  defp area([{duration, target} | stages], elapsed, from, acc) when elapsed >= duration do
    area(stages, elapsed - duration, target, acc + (from + target) / 2 * duration / 1000)
  end

  defp area([{duration, target} | _stages], elapsed, from, acc) do
    acc + (from * elapsed + (target - from) * elapsed * elapsed / (2 * duration)) / 1000
  end

  defp area([], _elapsed, _from, acc), do: acc

  # The part of `total` that falls to the node at `index` out of `count`.
  def share(total, index, count) do
    div(total, count) + if(index < rem(total, count), do: 1, else: 0)
  end

  defp plan(:vus, stages, _opts), do: %__MODULE__{mode: :vus, stages: normalize(stages, :vus)}

  defp plan(:rate, stages, opts) do
    %__MODULE__{mode: :rate, stages: normalize(stages, :rate), max_vus: max_vus!(opts[:max_vus])}
  end

  defp constant(_target, nil) do
    raise ArgumentError, "expected :duration to be given along with :vus or :rate"
  end

  defp constant(target, duration), do: [{0, target}, {duration, target}]

  defp normalize([_ | _] = stages, mode), do: Enum.map(stages, &normalize_stage(&1, mode))

  defp normalize(other, _mode) do
    raise ArgumentError, "expected stages to be a non-empty list, got: #{inspect(other)}"
  end

  defp normalize_stage({duration, target}, :vus) when is_integer(target) and target >= 0 do
    {milliseconds!(duration), target}
  end

  defp normalize_stage({duration, target}, :rate) when is_number(target) and target >= 0 do
    {milliseconds!(duration), target}
  end

  defp normalize_stage(other, mode) do
    target = if mode == :vus, do: "a non-negative integer", else: "a non-negative number"

    raise ArgumentError,
          "expected a stage to be a {duration, target} tuple with #{target} target, " <>
            "got: #{inspect(other)}"
  end

  defp max_vus!(max_vus) when is_integer(max_vus) and max_vus > 0, do: max_vus

  defp max_vus!(other) do
    raise ArgumentError, "expected :max_vus to be a positive integer, got: #{inspect(other)}"
  end

  def milliseconds!(:infinity) do
    raise ArgumentError, "expected durations to be finite, got: :infinity"
  end

  def milliseconds!(duration) do
    to_timeout(duration)
  rescue
    _error in [ArgumentError, FunctionClauseError] ->
      reraise ArgumentError,
              "expected a duration in milliseconds or anything accepted by " <>
                "to_timeout/1, got: #{inspect(duration)}",
              __STACKTRACE__
  end
end
