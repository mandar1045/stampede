defmodule Stampede.Address do
  @moduledoc false

  # Erlang looks up every host it's given as a string, even an IP address,
  # through one process and a pool of four OS helpers. At hundreds of new
  # connections a second that queue backs up, and lookups that time out come
  # back as :nxdomain, which looks like the server failing. So IP addresses are
  # parsed here, and host names are looked up once per node and kept for five
  # minutes, as k6 does by default. The name still goes to Mint as :hostname,
  # for the Host header, SNI and certificate checks.

  use GenServer

  @ttl :timer.minutes(5)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(__MODULE__, [:named_table, :public, read_concurrency: true])
    {:ok, nil}
  end

  # Returns the address to give `Mint.HTTP.connect/4` for `host`.
  def resolve(host) when is_binary(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, ip} -> {:ok, ip}
      {:error, :einval} -> cached(host)
    end
  end

  defp cached(host) do
    now = System.monotonic_time(:millisecond)

    case lookup(host) do
      [{^host, ip, expires_at}] when expires_at > now ->
        {:ok, ip}

      _missing_or_expired ->
        with {:ok, ip} <- getaddr(host) do
          store({host, ip, now + @ttl})
          {:ok, ip}
        end
    end
  end

  defp getaddr(host) do
    name = String.to_charlist(host)

    with {:error, _ipv4} <- :inet.getaddr(name, :inet),
         {:error, reason} <- :inet.getaddr(name, :inet6) do
      {:error, %Mint.TransportError{reason: reason}}
    end
  end

  # Without the application running, such as from a bare `mix run` that
  # skipped it, every lookup goes to the resolver.
  defp lookup(host) do
    :ets.lookup(__MODULE__, host)
  rescue
    ArgumentError -> []
  end

  defp store(entry) do
    :ets.insert(__MODULE__, entry)
  rescue
    ArgumentError -> true
  end
end
