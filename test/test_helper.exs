{:ok, _pid} =
  Supervisor.start_link(
    [{Phoenix.PubSub, name: Stampede.TestPubSub}, Stampede.TestEndpoint, Stampede.TestTLS],
    strategy: :one_for_one
  )

# Tests tagged :distributed start other nodes, which needs this one to be
# named, and epmd to be running.
distributed? =
  with epmd when is_list(epmd) <- :os.find_executable(~c"epmd"),
       {_output, 0} <- System.cmd(to_string(epmd), ["-daemon"]),
       {:ok, _pid} <- Node.start(:"stampede-#{System.pid()}@127.0.0.1", :longnames) do
    true
  else
    _error ->
      IO.puts("Skipping :distributed tests, as this node could not be named")
      false
  end

ExUnit.start(exclude: if(distributed?, do: [], else: [:distributed]))
