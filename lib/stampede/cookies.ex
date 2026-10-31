defmodule Stampede.Cookies do
  @moduledoc false

  # Cookies are kept as {name, "name=value"}, so a later Set-Cookie with the
  # same name replaces the earlier one. A VU's cookies live in its process, a
  # list for each host, the way its connections do. Path and Domain are
  # ignored, which fits testing one app, and a cookie only goes away when the
  # server says so with Max-Age=0, the way Plug deletes them.

  def store(cookies, headers) do
    for {"set-cookie", value} <- headers, reduce: cookies do
      cookies ->
        [pair | attributes] = String.split(value, ";")
        [name | _value] = String.split(pair, "=", parts: 2)

        if Enum.any?(attributes, &expired?/1),
          do: List.keydelete(cookies, name, 0),
          else: List.keystore(cookies, name, 0, {name, pair})
    end
  end

  defp expired?(attribute), do: attribute |> String.trim() |> String.downcase() == "max-age=0"

  def add_to(headers, []), do: headers

  def add_to(headers, cookies) do
    {given, headers} =
      Enum.split_with(headers, fn {name, _value} -> String.downcase(name) == "cookie" end)

    values = Enum.map(given, &elem(&1, 1)) ++ Enum.map(cookies, &elem(&1, 1))
    [{"cookie", Enum.join(values, "; ")} | headers]
  end

  def get(host), do: Process.get(__MODULE__, %{}) |> Map.get(host, [])

  def put(host, cookies) do
    Process.put(__MODULE__, Process.get(__MODULE__, %{}) |> Map.put(host, cookies))
  end

  def clear, do: Process.delete(__MODULE__)
end
