{:ok, _pid} =
  Supervisor.start_link(
    [{Phoenix.PubSub, name: Stampede.TestPubSub}, Stampede.TestEndpoint],
    strategy: :one_for_one
  )

ExUnit.start()
