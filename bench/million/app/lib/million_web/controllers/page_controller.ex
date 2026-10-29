defmodule MillionWeb.PageController do
  use MillionWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
