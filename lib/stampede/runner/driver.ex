defmodule Stampede.Runner.Driver do
  @moduledoc false

  # Runs the VUs of one node. The controller starts one driver per node and
  # sends them all :go at once. Every second, a driver sends the controller
  # how its metrics changed, and once the plan is over, all of its rows.

  alias Stampede.{Channels, Metrics, Plan, VU}

  @vus_tick 100
  @rate_tick 10
  @interval 1_000
  @error_pause 100

  def start(config) do
    {:ok, spawn(fn -> init(config) end)}
  end

  defp init(config) do
    Process.flag(:trap_exit, true)
    monitor = Process.monitor(config.controller)

    receive do
      :go -> run(Map.put(config, :monitor, monitor))
      :stop -> :ok
      {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
    end
  end

  defp run(config) do
    metrics = Metrics.new()

    state =
      Map.merge(config, %{
        metrics: metrics,
        vus: %{},
        idle: [],
        next_seq: 0,
        started: 0,
        interval: 0,
        snapshot: %{},
        reported_at: 0,
        started_at: now()
      })

    state = loop(state, Plan.duration(state.plan))
    elapsed = now() - state.started_at
    state = report(state, elapsed)
    stop(state)

    send(state.controller, {:done, self(), %{duration: elapsed, rows: Metrics.rows(metrics)}})
    :ets.delete(metrics)
  end

  defp loop(state, total) do
    elapsed = now() - state.started_at

    if elapsed < total do
      tick = if state.plan.mode == :vus, do: @vus_tick, else: @rate_tick

      state
      |> advance(elapsed)
      |> maybe_report(elapsed)
      |> wait(now() + min(tick, total - elapsed))
      |> loop(total)
    else
      state
    end
  end

  defp advance(%{plan: %{mode: :vus}} = state, elapsed) do
    total = round(Plan.target_at(state.plan, elapsed))
    target = Plan.share(total, state.index, state.count)

    case map_size(state.vus) do
      count when count < target ->
        Enum.reduce(1..(target - count), state, fn _, state -> start_vu(state, :closed) end)

      count when count > target ->
        stop_vus(state, Enum.take(Map.keys(state.vus), count - target))

      _count ->
        state
    end
  end

  defp advance(%{plan: %{mode: :rate}} = state, elapsed) do
    due = Plan.share(Plan.started_by(state.plan, elapsed), state.index, state.count)
    start_iterations(state, due - state.started)
  end

  defp start_iterations(state, count) when count <= 0, do: state

  defp start_iterations(state, count) do
    state =
      case state.idle do
        [pid | idle] ->
          send(pid, :iterate)
          %{state | idle: idle}

        [] ->
          if map_size(state.vus) < Plan.share(state.plan.max_vus, state.index, state.count) do
            start_vu(state, :open)
          else
            Metrics.increment(state.metrics, "iterations.dropped")
            state
          end
      end

    start_iterations(%{state | started: state.started + 1}, count - 1)
  end

  defp start_vu(state, kind) do
    %{scenario: scenario, data: data, metrics: metrics} = state
    driver = self()
    vu = %VU{id: state.index + 1 + state.count * state.next_seq, data: data}
    pid = spawn_link(fn -> run_vu(kind, driver, scenario, vu, metrics) end)
    %{state | vus: Map.put(state.vus, pid, vu.id), next_seq: state.next_seq + 1}
  end

  defp stop_vus(state, pids) do
    Enum.each(pids, &Process.exit(&1, :shutdown))
    %{state | vus: Map.drop(state.vus, pids), idle: state.idle -- pids}
  end

  defp wait(state, deadline) do
    %{monitor: monitor, vus: vus} = state

    receive do
      {:idle, pid} when is_map_key(vus, pid) ->
        continue(%{state | idle: [pid | state.idle]}, deadline)

      {:idle, _stopped} ->
        continue(state, deadline)

      {:EXIT, pid, reason} ->
        state |> exited(pid, reason) |> continue(deadline)

      :stop ->
        stop(state)
        exit(:normal)

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        stop(state)
        exit(:normal)
    after
      max(deadline - now(), 0) -> state
    end
  end

  # Messages can arrive faster than they are handled, so waiting stops at the
  # deadline even when more are queued.
  defp continue(state, deadline) do
    if now() < deadline, do: wait(state, deadline), else: state
  end

  defp exited(state, pid, reason) do
    case Map.pop(state.vus, pid) do
      {nil, _vus} ->
        state

      {_id, vus} ->
        if reason not in [:normal, :shutdown] do
          Metrics.increment(state.metrics, "vu.crashes")
        end

        %{state | vus: vus, idle: List.delete(state.idle, pid)}
    end
  end

  defp maybe_report(state, elapsed) do
    if elapsed - state.reported_at >= @interval, do: report(state, elapsed), else: state
  end

  defp report(state, elapsed) do
    snapshot = Metrics.snapshot(state.metrics)

    interval = %{
      index: state.interval,
      at: elapsed,
      vus: map_size(state.vus) - length(state.idle),
      delta: Metrics.delta(snapshot, state.snapshot)
    }

    send(state.controller, {:interval, self(), interval})
    %{state | interval: state.interval + 1, snapshot: snapshot, reported_at: elapsed}
  end

  defp stop(state) do
    state.vus |> Map.keys() |> Enum.each(&Process.exit(&1, :shutdown))
    await_exits(state.vus)
  end

  defp await_exits(vus) when map_size(vus) == 0, do: :ok

  defp await_exits(vus) do
    receive do
      {:EXIT, pid, _reason} -> await_exits(Map.delete(vus, pid))
    end
  end

  defp run_vu(kind, driver, scenario, vu, metrics) do
    Metrics.put_current(metrics)

    case kind do
      :closed -> closed_loop(scenario, vu, metrics)
      :open -> open_loop(driver, scenario, vu, metrics)
    end
  end

  # A VU of a :vus plan iterates for as long as it runs.
  defp closed_loop(scenario, vu, metrics) do
    if iterate(scenario, vu, metrics) == :error, do: Process.sleep(@error_pause)
    closed_loop(scenario, %{vu | iteration: vu.iteration + 1}, metrics)
  end

  # A VU of a :rate plan iterates when the driver says so, and keeps its
  # connections open in between.
  defp open_loop(driver, scenario, vu, metrics) do
    iterate(scenario, vu, metrics)
    send(driver, {:idle, self()})

    receive do
      :iterate -> open_loop(driver, scenario, %{vu | iteration: vu.iteration + 1}, metrics)
    end
  end

  defp iterate(scenario, vu, metrics) do
    started_at = System.monotonic_time()

    case run_iteration(scenario, vu) do
      :ok ->
        Metrics.record_since(metrics, "iteration", started_at)
        :ok

      {kind, reason, stacktrace} ->
        Metrics.increment(metrics, "iteration.errors")
        Metrics.error(metrics, kind, reason, stacktrace)
        :error
    end
  end

  defp run_iteration(scenario, vu) do
    scenario.run(vu)
    :ok
  catch
    kind, reason -> {kind, reason, __STACKTRACE__}
  after
    Channels.close_all()
  end

  defp now, do: System.monotonic_time(:millisecond)
end
