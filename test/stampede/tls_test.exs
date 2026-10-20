defmodule Stampede.TLSTest do
  use ExUnit.Case, async: true

  alias Stampede.{Channels, LiveView, TestTLS}

  # The test server's certificate is self-signed.
  @insecure [verify: :verify_none]

  test "Channels connect over wss" do
    {:ok, socket} = Channels.connect(TestTLS.url("wss", "/socket"), transport_opts: @insecure)

    assert {:ok, _reply} = Channels.join(socket, "room:lobby")
    assert {:ok, %{"pong" => %{}}} = Channels.push(socket, "room:lobby", "ping")
  end

  test "LiveViews connect over https" do
    {:ok, view} = LiveView.connect(TestTLS.url("https", "/counter"), transport_opts: @insecure)

    assert view.url == TestTLS.url("https", "/counter")
    assert {:ok, %{"count" => 0, "visitor" => "jo"}} = LiveView.click(view, "state")
  end

  test "certificates are verified unless told otherwise" do
    assert {:error, %Mint.TransportError{reason: {:tls_alert, _alert}}} =
             Channels.connect(TestTLS.url("wss", "/socket"))

    assert {:error, %Mint.TransportError{reason: {:tls_alert, _alert}}} =
             LiveView.connect(TestTLS.url("https", "/counter"))
  end
end
