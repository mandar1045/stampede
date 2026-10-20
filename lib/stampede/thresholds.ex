defmodule Stampede.Thresholds do
  @moduledoc false

  @stats [:min, :mean, :p50, :p90, :p95, :p99, :max, :count, :rate, :failed, :failed_rate]

  # Stats that are zero, rather than missing, when nothing was recorded.
  @zero_stats [:count, :rate, :failed, :failed_rate]

  def normalize(thresholds) when is_list(thresholds) do
    Enum.flat_map(thresholds, fn
      {metric, [_ | _] = limits} when is_binary(metric) ->
        Enum.map(limits, &normalize_limit(metric, &1))

      other ->
        raise ArgumentError,
              "expected a threshold to be a {metric, limits} tuple, such as " <>
                "{\"channel.join\", p95: 250}, got: #{inspect(other)}"
    end)
  end

  def normalize(other) do
    raise ArgumentError, "expected :thresholds to be a list, got: #{inspect(other)}"
  end

  def evaluate(thresholds, metrics) do
    for {metric, stat, limit} <- thresholds do
      value = value(Map.get(metrics, metric), stat)
      %{metric: metric, stat: stat, limit: limit, value: value, passed?: passed?(value, limit)}
    end
  end

  defp normalize_limit(metric, {stat, limit}) when stat in @stats and is_number(limit) do
    {metric, stat, limit}
  end

  defp normalize_limit(metric, other) do
    raise ArgumentError,
          "invalid limit #{inspect(other)} for #{inspect(metric)}, expected one of " <>
            "#{inspect(@stats)} followed by a number"
  end

  defp value(nil, stat) when stat in @zero_stats, do: 0
  defp value(nil, _stat), do: nil
  defp value(summary, stat), do: Map.get(summary, stat)

  defp passed?(value, limit), do: is_number(value) and value <= limit
end
