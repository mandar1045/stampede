defmodule Stampede.Runner.Driver do
  @moduledoc false

  # Runs the VUs of one node. The controller starts one driver per node and
  # sends them all :go at once. Every second, a driver sends the controller
  # how its metrics changed, and once the plan is over, all of its rows.

  alias Stampede.{Channels, Metrics, Plan, VU, WebSocket}

  @vus_tick 100
  @rate_tick 10
  @finish_tick 10
  @interval 1_000
  # After an iteration fails, a VU waits before the next one, longer each time
  # it fails in a row, much like Phoenix's JavaScript client before it
  # reconnects. A server in trouble then isn't hammered by every VU at once.
  @backoff [100, 150, 200, 250, 500, 1_000, 2_000]
  @max_backoff 5_000

  def start(config) do
    {:ok, spawn(fn -> init(config) end)}
  end

  defp init(config) do
    # Like the controller, so that the run goes on while VUs keep the node
    # busy.
    Process.flag(:priority, :high)
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
    :erlang.system_flag(:scheduler_wall_time, true)

    state =
      Map.merge(config, %{
        metrics: metrics,
        vus: %{},
        idle: [],
        stopping: %{},
        next_seq: 0,
        started: 0,
        interval: 0,
        snapshot: %{},
        reported_at: 0,
        scheduler_time: scheduler_time(),
        wrapped: false,
        started_at: now()
      })

    state = loop(state, Plan.duration(state.plan))
    state = report(state, now() - state.started_at)
    state = state |> stop_vus(Map.keys(state.vus)) |> finish()
    stop(state)

    final = %{duration: state.reported_at, rows: Metrics.rows(metrics)}
    send(state.controller, {:done, self(), final})
    :ets.delete(metrics)
  end

  defp loop(state, total) do
    elapsed = now() - state.started_at

    if elapsed < total and not state.wrapped do
      tick = if state.plan.mode == :vus, do: @vus_tick, else: @rate_tick

      state
      |> advance(elapsed)
      |> expire()
      |> maybe_report(elapsed)
      |> wait(now() + min(tick, total - elapsed))
      |> loop(total)
    else
      state
    end
  end

  # After the plan, VUs still finishing an iteration get until their deadline,
  # and the time they take is reported as one more interval.
  defp finish(state) when map_size(state.stopping) == 0, do: state

  defp finish(state) do
    state = state |> wait(now() + @finish_tick) |> expire()
    elapsed = now() - state.started_at

    if map_size(state.stopping) == 0 do
      report(state, elapsed)
    else
      state |> maybe_report(elapsed) |> finish()
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

  # VUs that are no longer needed stop at once, or, with a graceful stop, once
  # their current iteration is over. Either way they stop counting as running.
  defp stop_vus(%{graceful_stop: 0} = state, pids) do
    Enum.each(pids, &Process.exit(&1, :shutdown))
    %{state | vus: Map.drop(state.vus, pids), idle: state.idle -- pids}
  end

  defp stop_vus(state, pids) do
    deadline = now() + state.graceful_stop
    Enum.each(pids, &send(&1, :finish))
    stopping = Map.merge(state.stopping, Map.new(pids, &{&1, deadline}))
    %{state | vus: Map.drop(state.vus, pids), idle: state.idle -- pids, stopping: stopping}
  end

  defp expire(state) do
    now = now()
    {late, stopping} = Map.split_with(state.stopping, fn {_pid, deadline} -> deadline <= now end)
    Enum.each(late, fn {pid, _deadline} -> Process.exit(pid, :shutdown) end)
    %{state | stopping: stopping}
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

      # The controller found what it was looking for, such as a limit, so the
      # plan ends early, the same way it does at its end.
      :wrap_up ->
        %{state | wrapped: true}

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
    cond do
      Map.has_key?(state.vus, pid) ->
        if reason not in [:normal, :shutdown] do
          Metrics.increment(state.metrics, "vu.crashes")
        end

        %{state | vus: Map.delete(state.vus, pid), idle: List.delete(state.idle, pid)}

      Map.has_key?(state.stopping, pid) ->
        %{state | stopping: Map.delete(state.stopping, pid)}

      true ->
        state
    end
  end

  defp maybe_report(state, elapsed) do
    if elapsed - state.reported_at >= @interval, do: report(state, elapsed), else: state
  end

  defp report(state, elapsed) do
    snapshot = Metrics.snapshot(state.metrics)
    scheduler_time = scheduler_time()

    interval = %{
      index: state.interval,
      at: elapsed,
      vus: map_size(state.vus) - length(state.idle) + map_size(state.stopping),
      delta: Metrics.delta(snapshot, state.snapshot),
      busy: busy(state.scheduler_time, scheduler_time)
    }

    send(state.controller, {:interval, self(), interval})

    %{
      state
      | interval: state.interval + 1,
        snapshot: snapshot,
        reported_at: elapsed,
        scheduler_time: scheduler_time
    }
  end

  # How busy this node's schedulers were between two samples, from 0 to 1.
  # A load test that's too busy measures its own delays as well as the
  # server's, so the run reports it. Schedulers spinning while they wait
  # don't count as busy.
  defp scheduler_time do
    count = :erlang.system_info(:schedulers)

    :erlang.statistics(:scheduler_wall_time)
    |> Enum.filter(fn {id, _active, _total} -> id <= count end)
    |> Enum.sort()
  end

  defp busy(before, now) do
    {active, total} =
      Enum.zip_reduce(before, now, {0, 0}, fn {_, active1, total1},
                                              {_, active2, total2},
                                              {a, t} ->
        {a + active2 - active1, t + total2 - total1}
      end)

    if total > 0, do: active / total, else: 0.0
  end

  defp stop(state) do
    vus = Map.merge(state.vus, state.stopping)
    vus |> Map.keys() |> Enum.each(&Process.exit(&1, :shutdown))
    await_exits(vus)
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
      :closed -> closed_loop(scenario, vu, metrics, 0)
      :open -> open_loop(driver, scenario, vu, metrics)
    end
  end

  # A VU of a :vus plan iterates until the driver asks it to finish.
  defp closed_loop(scenario, vu, metrics, failures) do
    {failures, pause} =
      case iterate(scenario, vu, metrics) do
        :ok -> {0, 0}
        :error -> {failures + 1, Enum.at(@backoff, failures, @max_backoff)}
      end

    receive do
      :finish -> :ok
    after
      pause -> closed_loop(scenario, %{vu | iteration: vu.iteration + 1}, metrics, failures)
    end
  end

  # A VU of a :rate plan iterates when the driver says so, and keeps its
  # connections open in between.
  defp open_loop(driver, scenario, vu, metrics) do
    iterate(scenario, vu, metrics)
    send(driver, {:idle, self()})

    receive do
      :iterate -> open_loop(driver, scenario, %{vu | iteration: vu.iteration + 1}, metrics)
      :finish -> :ok
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
    WebSocket.close_all()
  end

  defp now, do: System.monotonic_time(:millisecond)
end
