defmodule Stampede.Metrics do
  @moduledoc false

  # Timings are counted in buckets whose bounds grow by a constant factor, as
  # in DDSketch, so the value read back from a bucket is within 1% of every
  # sample that went into it.
  @accuracy 0.01
  @gamma (1 + @accuracy) / (1 - @accuracy)
  @log_gamma :math.log(@gamma)

  @key {__MODULE__, :table}

  def new do
    :ets.new(__MODULE__, [:set, :public, write_concurrency: true, decentralized_counters: true])
  end

  def put_current(table), do: Process.put(@key, table)

  def current, do: Process.get(@key)

  def record_since(table, name, started_at) do
    duration = System.monotonic_time() - started_at
    record(table, name, System.convert_time_unit(duration, :native, :microsecond))
  end

  def record(table, name, microseconds) do
    update(table, {:timing, name, bucket(microseconds)}, 1)
    update(table, {:sum, name}, microseconds)
  end

  def increment(table, name, amount \\ 1), do: update(table, {:counter, name}, amount)

  def error(nil, _kind, _reason, _stacktrace), do: :ok

  def error(table, kind, reason, stacktrace) do
    key = error_key(kind, reason)
    update(table, {:error, key}, 1)

    message =
      kind
      |> Exception.format_banner(reason, stacktrace)
      |> String.replace(~r/\s+/, " ")
      |> String.slice(0, 300)

    :ets.insert_new(table, {{:error_message, key}, message})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def count(table, name) do
    timings = :ets.select(table, [{{{:timing, name, :_}, :"$1"}, [], [:"$1"]}])

    case :ets.lookup(table, {:counter, name}) do
      [{_key, count}] -> Enum.sum(timings) + count
      [] -> Enum.sum(timings)
    end
  end

  def summary(table, duration) do
    rows = :ets.tab2list(table)
    seconds = max(duration, 1) / 1000
    sums = for {{:sum, name}, sum} <- rows, into: %{}, do: {name, sum}

    counters =
      for {{:counter, name}, count} <- rows, into: %{} do
        {name, %{type: :counter, count: count, rate: count / seconds}}
      end

    timings =
      for({{:timing, name, bucket}, count} <- rows, do: {name, {bucket, count}})
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {name, buckets} ->
        {name, timing(Enum.sort(buckets), Map.fetch!(sums, name), seconds)}
      end)

    messages = for {{:error_message, key}, message} <- rows, into: %{}, do: {key, message}

    errors =
      for({{:error, key}, count} <- rows, do: %{message: Map.fetch!(messages, key), count: count})
      |> Enum.sort_by(& &1.count, :desc)

    %{metrics: Map.merge(counters, timings), errors: errors}
  end

  defp timing(buckets, sum, seconds) do
    count = buckets |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    mean = sum / count
    {first, _count} = hd(buckets)
    {last, _count} = List.last(buckets)

    %{
      type: :timing,
      count: count,
      rate: count / seconds,
      min: to_milliseconds(min(value(first), mean)),
      mean: to_milliseconds(mean),
      p50: percentile(buckets, count, 0.50),
      p90: percentile(buckets, count, 0.90),
      p95: percentile(buckets, count, 0.95),
      p99: percentile(buckets, count, 0.99),
      max: to_milliseconds(max(value(last), mean))
    }
  end

  defp percentile(buckets, count, quantile) do
    rank = max(ceil(quantile * count), 1)

    buckets
    |> Enum.reduce_while(0, fn {bucket, bucket_count}, seen ->
      if seen + bucket_count >= rank,
        do: {:halt, value(bucket)},
        else: {:cont, seen + bucket_count}
    end)
    |> to_milliseconds()
  end

  defp bucket(0), do: 0
  defp bucket(microseconds), do: ceil(:math.log(microseconds) / @log_gamma) + 1

  defp value(0), do: 0
  defp value(bucket), do: 2 * :math.pow(@gamma, bucket - 1) / (@gamma + 1)

  defp to_milliseconds(microseconds), do: microseconds / 1000

  defp error_key(:error, reason), do: Exception.normalize(:error, reason).__struct__

  defp error_key(:exit, reason) when is_tuple(reason) and tuple_size(reason) > 0,
    do: {:exit, elem(reason, 0)}

  defp error_key(kind, reason) when is_atom(reason), do: {kind, reason}
  defp error_key(kind, _reason), do: kind

  defp update(nil, _key, _amount), do: :ok

  defp update(table, key, amount) do
    :ets.update_counter(table, key, amount, {key, 0})
    :ok
  rescue
    # The table is deleted when a run ends, while sockets may still be closing.
    ArgumentError -> :ok
  end
end
