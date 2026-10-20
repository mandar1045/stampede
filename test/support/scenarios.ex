# Scenarios shared by the tests. They live here, compiled to .beam files,
# so that other nodes can load them too. Runs that need a few iterations
# last a second, since the first connections of a test run are slow while
# the server's modules load.

defmodule Stampede.Test.Lingering do
  use Stampede.Scenario

  @impl true
  def run(_vu) do
    Stampede.increment("started")
    Process.sleep(300)
    Stampede.increment("finished")
  end
end

defmodule Stampede.Test.Echoing do
  use Stampede.Scenario

  @impl true
  def run(_vu) do
    {:ok, ws} = Stampede.WebSocket.connect(Stampede.TestEndpoint.echo_url())
    {:ok, {:text, "welcome"}} = Stampede.WebSocket.await(ws)
    :ok = Stampede.WebSocket.send(ws, "hello")
    {:ok, {:text, "hello"}} = Stampede.WebSocket.await(ws)
    Process.sleep(10)
  end
end

defmodule Stampede.Test.Lobby do
  use Stampede.Scenario

  @impl true
  def options, do: [vus: 2, duration: 1_000]

  @impl true
  def run(_vu) do
    {:ok, socket} = Stampede.Channels.connect(Stampede.TestEndpoint.socket_url())
    {:ok, _reply} = Stampede.Channels.join(socket, "room:lobby")
    {:ok, _reply} = Stampede.Channels.push(socket, "room:lobby", "ping")
    Process.sleep(10)
  end
end

defmodule Stampede.Test.Failing do
  use Stampede.Scenario

  @impl true
  def run(%{iteration: 0}), do: raise("boom")
  def run(_vu), do: Process.sleep(10)
end

defmodule Stampede.Test.Custom do
  use Stampede.Scenario

  @impl true
  def setup(opts), do: %{vus: opts[:vus]}

  @impl true
  def run(vu) do
    Stampede.increment("seen.#{vu.id}")
    Stampede.increment("setup.#{vu.data.vus}")
    Stampede.measure("nap", fn -> Process.sleep(5) end)
    Stampede.record("server", 7)
  end
end

defmodule Stampede.Test.Reconnecting do
  use Stampede.Scenario

  @impl true
  def setup(_opts), do: self()

  @impl true
  def run(vu) do
    if previous = Process.get(:socket) do
      Stampede.increment(if Process.alive?(previous), do: "leaked", else: "closed")
    end

    {:ok, socket} = Stampede.Channels.connect(Stampede.TestEndpoint.socket_url())
    Process.put(:socket, socket)
    send(vu.data, {:iteration, self(), socket})
    Process.sleep(10)
  end
end

defmodule Stampede.Test.Arriving do
  use Stampede.Scenario

  @impl true
  def setup(_opts), do: 20

  @impl true
  def run(vu) do
    Stampede.increment("arriving.#{vu.id}")
    Process.sleep(vu.data)
  end
end

defmodule Stampede.Test.Slow do
  use Stampede.Scenario

  @impl true
  def run(_vu), do: Process.sleep(200)
end

defmodule Stampede.Test.Checking do
  use Stampede.Scenario

  @impl true
  def run(vu) do
    Stampede.check("even iteration", rem(vu.iteration, 2) == 0)
    Process.sleep(5)
  end
end

defmodule Stampede.Test.Observed do
  use Stampede.Scenario

  @impl true
  def run(_vu), do: Process.sleep(10)
end

defmodule Stampede.Test.Crashing do
  use Stampede.Scenario

  @impl true
  def run(%{id: 1, iteration: 0}) do
    spawn_link(fn -> exit(:boom) end)
    Process.sleep(:infinity)
  end

  def run(vu), do: Stampede.increment("ran.#{vu.id}")
end

defmodule Stampede.Test.Spread do
  use Stampede.Scenario

  @impl true
  def setup(_opts), do: Stampede.TestEndpoint.socket_url()

  @impl true
  def run(vu) do
    Stampede.increment("on.#{node()}")
    Stampede.increment("vu.#{vu.id}")
    {:ok, socket} = Stampede.Channels.connect(vu.data)
    {:ok, _reply} = Stampede.Channels.join(socket, "room:lobby")
    Process.sleep(20)
  end
end
