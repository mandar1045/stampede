defmodule Stampede.HTTPConnectionRetirementTest do
  use ExUnit.Case, async: true
  alias Stampede.HTTP

  for method <- [:post, :patch] do
    @tag :known_closed
    test "retires a known closed cache before sending #{method}" do
      {url, listener, server} = fixture(:idle)
      method = unquote(method)
      assert {:ok, %{status: 200}} = HTTP.request(method, url, body: "first", metric: nil)
      assert_receive {:received, ^server, 1, "first"}

      uri = URI.parse(url)
      conn = Process.get({HTTP, uri.scheme, uri.host, uri.port, []})
      socket = Mint.HTTP.get_socket(conn)
      send(server, :close_idle)
      assert_receive {:tcp_closed, ^socket}, 1000
      # Let the normal cache refresh consume the already-observed close.
      send(self(), {:tcp_closed, socket})

      assert {:ok, %{status: 200}} = HTTP.request(method, url, body: "second", metric: nil)
      assert_receive {:received, ^server, 2, "second"}
      refute_receive {:received, ^server, 3, _}, 50
      :gen_tcp.close(listener)
    end
  end

  for mode <- [:no_headers, :partial_body] do
    test "does not replay POST after the server received it and closed at #{mode}" do
      {url, listener, server} = fixture(unquote(mode))
      assert {:ok, %{status: 200}} = HTTP.post(url, body: "first", metric: nil)
      assert_receive {:received, ^server, 1, "first"}

      assert {:error, %Mint.TransportError{reason: :closed}} =
               HTTP.post(url, body: "second", metric: nil)

      assert_receive {:received, ^server, 2, "second"}
      refute_receive {:unexpected_connection, ^server}, 100
      :gen_tcp.close(listener)
    end
  end

  defp fixture(mode) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    {:ok, server} =
      Task.start(fn ->
        {:ok, first} = :gen_tcp.accept(listener)
        request(first, parent, 1)
        reply(first)

        case mode do
          :idle ->
            receive do
              :close_idle -> :gen_tcp.close(first)
            end

            {:ok, second} = :gen_tcp.accept(listener)
            request(second, parent, 2)
            reply(second)
            :gen_tcp.close(second)

          other ->
            request(first, parent, 2)

            if other == :partial_body,
              do: :gen_tcp.send(first, "HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\npart")

            :gen_tcp.close(first)

            case :gen_tcp.accept(listener, 500) do
              {:ok, unexpected} ->
                send(parent, {:unexpected_connection, self()})
                :gen_tcp.close(unexpected)

              {:error, _} ->
                :ok
            end
        end
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(server), do: Process.exit(server, :kill)
    end)

    {"http://127.0.0.1:#{port}/", listener, server}
  end

  defp request(socket, parent, ordinal) do
    {headers, body} = headers(socket, "")
    [_, length] = Regex.run(~r/content-length:\s*(\d+)/i, headers)
    length = String.to_integer(length)
    body = body(socket, body, length)
    send(parent, {:received, self(), ordinal, body})
  end

  defp headers(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, body] ->
        {head, body}

      [_] ->
        {:ok, bytes} = :gen_tcp.recv(socket, 0, 1000)
        headers(socket, buffer <> bytes)
    end
  end

  defp body(_socket, body, length) when byte_size(body) == length, do: body

  defp body(socket, body, length) do
    {:ok, bytes} = :gen_tcp.recv(socket, length - byte_size(body), 1000)
    body(socket, body <> bytes, length)
  end

  defp reply(socket),
    do: :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
end
