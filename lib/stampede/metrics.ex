defmodule Stampede.Metrics do
  @moduledoc false

  # Timings are counted in buckets whose bounds grow by a constant factor, as
  # in DDSketch, so the value read back from a bucket is within 1% of every
  # sample that went into it. Buckets from several nodes or several seconds
  # merge by adding their counts.
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
    record(table, name, System.monotonic_time() - started_at)
  end

  # `duration` is in native time units, like every duration in telemetry.
  def record(nil, _name, _duration), do: :ok

  def record(table, name, duration) do
    microseconds = System.convert_time_unit(duration, :native, :microsecond)
    update(table, {:timing, name, bucket(microseconds)}, 1)
    update(table, {:sum, name}, microseconds)
    :telemetry.execute([:stampede, :timing], %{duration: duration}, %{name: name})
  end

  def increment(table, name, amount \\ 1)
  def increment(nil, _name, _amount), do: :ok

  def increment(table, name, amount) do
    update(table, {:counter, name}, amount)
    :telemetry.execute([:stampede, :counter], %{count: amount}, %{name: name})
  end

  def check(nil, _name, _passed?), do: :ok

  def check(table, name, passed?) do
    update(table, {:check, name, passed?}, 1)
    :telemetry.execute([:stampede, :check], %{count: 1}, %{name: name, passed?: passed?})
  end

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

  def rows(table), do: :ets.tab2list(table)

  # The counts in `table`, to compare with an earlier snapshot.
  def snapshot(table) do
    for {key, value} <- :ets.tab2list(table), is_integer(value), into: %{}, do: {key, value}
  end

  def delta(current, previous) do
    Enum.reduce(current, %{}, fn {key, value}, delta ->
      case value - Map.get(previous, key, 0) do
        0 -> delta
        difference -> Map.put(delta, key, difference)
      end
    end)
  end

  # Adds up the counts in lists of rows, keeping the first error message.
  def merge(rows_lists) do
    rows_lists
    |> Enum.reduce(%{}, fn rows, merged ->
      Enum.reduce(rows, merged, fn
        {key, value}, merged when is_integer(value) ->
          Map.update(merged, key, value, &(&1 + value))

        {key, value}, merged ->
          Map.put_new(merged, key, value)
      end)
    end)
    |> Map.to_list()
  end

  def count(rows, name) do
    Enum.reduce(rows, 0, fn
      {{:timing, ^name, _bucket}, count}, total -> total + count
      {{:counter, ^name}, count}, total -> total + count
      _row, total -> total
    end)
  end

  def summary(rows, duration) do
    rows = Enum.to_list(rows)
    seconds = max(duration, 1) / 1000
    sums = for {{:sum, name}, sum} <- rows, into: %{}, do: {name, sum}

    counters =
      for {{:counter, name}, count} <- rows, into: %{} do
        {name, %{type: :counter, count: count, rate: count / seconds}}
      end

    checks =
      for({{:check, name, passed?}, count} <- rows, do: {name, {passed?, count}})
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {name, results} -> {name, check_summary(results, seconds)} end)

    # A snapshot can fall between the two updates of one sample, so a bucket
    # may be counted before its sum is.
    timings =
      for({{:timing, name, bucket}, count} <- rows, do: {name, {bucket, count}})
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {name, buckets} ->
        {name, timing_summary(Enum.sort(buckets), Map.get(sums, name, 0), seconds)}
      end)

    messages = for {{:error_message, key}, message} <- rows, into: %{}, do: {key, message}

    errors =
      for {{:error, key}, count} <- rows do
        %{message: Map.get_lazy(messages, key, fn -> inspect(key) end), count: count}
      end

    %{
      metrics: counters |> Map.merge(checks) |> Map.merge(timings),
      errors: Enum.sort_by(errors, & &1.count, :desc)
    }
  end

  defp check_summary(results, seconds) do
    passed = Enum.sum(for {true, count} <- results, do: count)
    failed = Enum.sum(for {false, count} <- results, do: count)
    count = passed + failed

    %{
      type: :check,
      count: count,
      rate: count / seconds,
      passed: passed,
      failed: failed,
      failed_rate: failed / count
    }
  end

  defp timing_summary(buckets, sum, seconds) do
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

  defp update(table, key, amount) do
    :ets.update_counter(table, key, amount, {key, 0})
    :ok
  rescue
    # The table is deleted when a run ends, while sockets may still be closing.
    ArgumentError -> :ok
  end
end
