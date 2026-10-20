defmodule Stampede.Runner do
  @moduledoc false

  alias Stampede.{Channels, Metrics, Result, Stages, Thresholds, VU}

  @tick 100
  @progress_interval 1_000
  @error_pause 100

  def run(scenario, opts) when is_atom(scenario) and is_list(opts) do
    Code.ensure_loaded!(scenario)

    if not function_exported?(scenario, :run, 1) do
      raise ArgumentError, "expected #{inspect(scenario)} to implement Stampede.Scenario"
    end

    opts =
      scenario
      |> default_options()
      |> Keyword.merge(opts)
      |> Keyword.validate!(stages: nil, vus: 1, duration: nil, thresholds: [], progress: false)

    stages = Stages.from_options(opts)
    thresholds = Thresholds.normalize(opts[:thresholds])
    data = if function_exported?(scenario, :setup, 1), do: scenario.setup(opts)
    metrics = Metrics.new()

    config = %{
      caller: self(),
      scenario: scenario,
      data: data,
      metrics: metrics,
      stages: stages,
      progress?: opts[:progress]
    }

    # The VUs are driven from their own process, which traps exits, so that a
    # crashing VU becomes a message instead of taking the caller down.
    duration = fn -> drive(config) end |> Task.async() |> Task.await(:infinity)

    summary = Metrics.summary(metrics, duration)
    :ets.delete(metrics)
    Result.new(scenario, duration, summary, Thresholds.evaluate(thresholds, summary.metrics))
  end

  defp default_options(scenario) do
    if function_exported?(scenario, :options, 0), do: scenario.options(), else: []
  end

  defp drive(config) do
    Process.flag(:trap_exit, true)

    state = Map.merge(config, %{vus: %{}, next_id: 1, started_at: now(), reported_at: 0})
    state = loop(state, Stages.duration(state.stages))
    duration = now() - state.started_at

    state.vus |> Map.keys() |> Enum.each(&Process.exit(&1, :shutdown))
    await_exits(state.vus)
    duration
  end

  defp await_exits(vus) when map_size(vus) == 0, do: :ok

  defp await_exits(vus) do
    receive do
      {:EXIT, pid, _reason} -> await_exits(Map.delete(vus, pid))
    end
  end

  defp loop(state, total) do
    elapsed = now() - state.started_at

    if elapsed < total do
      state
      |> scale(Stages.target_at(state.stages, elapsed))
      |> report_progress()
      |> wait(now() + min(@tick, total - elapsed))
      |> loop(total)
    else
      state
    end
  end

  defp scale(state, target) do
    case map_size(state.vus) do
      count when count < target -> start_vus(state, target - count)
      count when count > target -> stop_vus(state, Enum.take(Map.keys(state.vus), count - target))
      _count -> state
    end
  end

  defp start_vus(state, count) do
    %{scenario: scenario, data: data, metrics: metrics} = state

    Enum.reduce(1..count, state, fn _, state ->
      vu = %VU{id: state.next_id, data: data}
      pid = spawn_link(fn -> run_vu(scenario, vu, metrics) end)
      %{state | vus: Map.put(state.vus, pid, vu.id), next_id: state.next_id + 1}
    end)
  end

  defp stop_vus(state, pids) do
    for pid <- pids, do: Process.exit(pid, :shutdown)
    %{state | vus: Map.drop(state.vus, pids)}
  end

  defp wait(state, deadline) do
    caller = state.caller

    receive do
      {:EXIT, ^caller, reason} ->
        stop_vus(state, Map.keys(state.vus))
        exit(reason)

      {:EXIT, pid, reason} ->
        state = exited(state, pid, reason)
        if now() < deadline, do: wait(state, deadline), else: state
    after
      max(deadline - now(), 0) -> state
    end
  end

  defp exited(state, pid, reason) do
    case Map.pop(state.vus, pid) do
      {nil, _vus} ->
        state

      {_id, vus} ->
        if reason not in [:normal, :shutdown] do
          Metrics.increment(state.metrics, "vu.crashes")
        end

        %{state | vus: vus}
    end
  end

  defp report_progress(%{progress?: true, reported_at: reported_at} = state) do
    elapsed = now() - state.started_at

    if elapsed - reported_at >= @progress_interval do
      IO.puts(
        "#{seconds(elapsed)}  vus: #{map_size(state.vus)}  " <>
          "iterations: #{Metrics.count(state.metrics, "iteration")}  " <>
          "errors: #{Metrics.count(state.metrics, "iteration.errors")}"
      )

      %{state | reported_at: elapsed}
    else
      state
    end
  end

  defp report_progress(state), do: state

  defp run_vu(scenario, vu, metrics) do
    Metrics.put_current(metrics)
    iterate(scenario, vu, metrics)
  end

  defp iterate(scenario, vu, metrics) do
    started_at = System.monotonic_time()

    case run_iteration(scenario, vu) do
      :ok ->
        Metrics.record_since(metrics, "iteration", started_at)

      {kind, reason, stacktrace} ->
        Metrics.increment(metrics, "iteration.errors")
        Metrics.error(metrics, kind, reason, stacktrace)
        Process.sleep(@error_pause)
    end

    iterate(scenario, %{vu | iteration: vu.iteration + 1}, metrics)
  end

  defp run_iteration(scenario, vu) do
    scenario.run(vu)
    :ok
  catch
    kind, reason -> {kind, reason, __STACKTRACE__}
  after
    Channels.close_all()
  end

  defp seconds(milliseconds) do
    String.pad_leading(:erlang.float_to_binary(milliseconds / 1000, decimals: 1) <> "s", 7)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
