defmodule Stampede.AddressTest do
  use ExUnit.Case, async: true

  alias Stampede.Address

  test "parses IP addresses without looking them up" do
    assert Address.resolve("127.0.0.1") == {:ok, {127, 0, 0, 1}}
    assert Address.resolve("::1") == {:ok, {0, 0, 0, 0, 0, 0, 0, 1}}
    assert :ets.lookup(Address, "127.0.0.1") == []
  end

  test "looks a host name up once and keeps it" do
    assert {:ok, ip} = Address.resolve("localhost")
    assert [{"localhost", ^ip, _expires_at}] = :ets.lookup(Address, "localhost")
    assert Address.resolve("localhost") == {:ok, ip}
  end

  # Thousands of connections starting at once used to queue for Erlang's
  # resolver, and time out as :nxdomain.
  test "resolves for many VUs at once without errors" do
    results =
      1..20_000
      |> Task.async_stream(
        fn i -> Address.resolve(if rem(i, 2) == 0, do: "localhost", else: "10.0.0.1") end,
        max_concurrency: 5_000
      )
      |> Enum.map(fn {:ok, result} -> elem(result, 0) end)

    assert Enum.uniq(results) == [:ok]
  end
end
