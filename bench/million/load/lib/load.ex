defmodule Load do
  @moduledoc """
  Settings shared by the scenarios, read from the environment of each node.

    * `SERVER` - the app's address, such as `172.31.0.10:4000`
    * `SOURCE_IPS` - the local addresses to connect from, separated by
      commas. One address only gets about 64,000 ports to the server, so a
      machine holding 250,000 connections needs several.
    * `VUS`, `RAMP` and `HOLD` - how many VUs, and for how many seconds to
      ramp up to them and to hold them
    * `PAUSE` - the range of seconds a VU waits between messages, `30-60` by
      default. `120-240` is a quieter crowd, closer to people who mostly read.
    * `STEP_RAMP` - with `--find-limit`, how many seconds each step takes to
      reach its VUs, so that 100,000 more don't arrive at once
  """

  def options(thresholds) do
    case System.get_env("STEP_RAMP") do
      nil -> [stages: stages(), thresholds: thresholds]
      ramp -> [find_limit: [ramp: [second: String.to_integer(ramp)]], thresholds: thresholds]
    end
  end

  def stages do
    vus = env_integer("VUS", 1_000)
    [{[second: env_integer("RAMP", 60)], vus}, {[second: env_integer("HOLD", 60)], vus}]
  end

  def url(scheme, path), do: "#{scheme}://#{System.get_env("SERVER", "localhost:4000")}#{path}"

  # Each VU sticks to one of the node's addresses, spread by its id.
  def transport_opts(vu) do
    case System.get_env("SOURCE_IPS", "") |> String.split(",", trim: true) do
      [] ->
        []

      ips ->
        ip = Enum.at(ips, :erlang.phash2(vu.id, length(ips)))
        {:ok, address} = :inet.parse_address(String.to_charlist(ip))
        [ip: address]
    end
  end

  # Waits a random time within `PAUSE`, so that VUs don't act in lockstep.
  def pause do
    [low, high] =
      System.get_env("PAUSE", "30-60") |> String.split("-") |> Enum.map(&String.to_integer/1)

    Process.sleep((low + :rand.uniform(high - low + 1) - 1) * 1000)
  end

  defp env_integer(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end
end
