defmodule Stampede.TestTLS do
  # Serves the test endpoint over TLS too, with a certificate signed by a
  # throwaway root that clients do not trust.

  def child_spec(_opts) do
    rsa = [key: {:rsa, 2048, 65537}]

    %{server_config: server_config} =
      :public_key.pkix_test_data(%{
        server_chain: %{root: rsa, peer: rsa},
        client_chain: %{root: rsa, peer: rsa}
      })

    [
      plug: Stampede.TestEndpoint,
      scheme: :https,
      ip: {127, 0, 0, 1},
      port: 0,
      startup_log: false,
      thousand_island_options: [
        supervisor_options: [name: __MODULE__],
        transport_options: Keyword.take(server_config, [:cert, :key, :cacerts])
      ]
    ]
    |> Bandit.child_spec()
    |> Map.put(:id, __MODULE__)
  end

  def url(scheme, path) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(__MODULE__)
    "#{scheme}://127.0.0.1:#{port}#{path}"
  end
end
