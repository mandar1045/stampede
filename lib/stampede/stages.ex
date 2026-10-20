defmodule Stampede.Stages do
  @moduledoc false

  def from_options(opts) do
    case Keyword.fetch!(opts, :stages) do
      nil -> constant(Keyword.fetch!(opts, :vus), Keyword.fetch!(opts, :duration))
      stages -> normalize(stages)
    end
  end

  def duration(stages) do
    stages |> Enum.map(&elem(&1, 0)) |> Enum.sum()
  end

  def target_at(stages, elapsed), do: target_at(stages, elapsed, 0)

  defp target_at([{duration, target} | stages], elapsed, _from) when elapsed >= duration do
    target_at(stages, elapsed - duration, target)
  end

  defp target_at([{duration, target} | _stages], elapsed, from) do
    from + round((target - from) * elapsed / duration)
  end

  defp target_at([], _elapsed, from), do: from

  defp constant(_vus, nil) do
    raise ArgumentError, "expected either :stages or :duration to be given"
  end

  defp constant(vus, duration), do: normalize([{0, vus}, {duration, vus}])

  defp normalize([_ | _] = stages), do: Enum.map(stages, &normalize_stage/1)

  defp normalize(other) do
    raise ArgumentError, "expected :stages to be a non-empty list, got: #{inspect(other)}"
  end

  defp normalize_stage({duration, target}) when is_integer(target) and target >= 0 do
    {milliseconds!(duration), target}
  end

  defp normalize_stage(other) do
    raise ArgumentError,
          "expected a stage to be a {duration, target} tuple with a non-negative " <>
            "integer target, got: #{inspect(other)}"
  end

  defp milliseconds!(:infinity) do
    raise ArgumentError, "expected stage durations to be finite, got: :infinity"
  end

  defp milliseconds!(duration) do
    to_timeout(duration)
  rescue
    _error in [ArgumentError, FunctionClauseError] ->
      reraise ArgumentError,
              "expected a duration in milliseconds or anything accepted by " <>
                "to_timeout/1, got: #{inspect(duration)}",
              __STACKTRACE__
  end
end
