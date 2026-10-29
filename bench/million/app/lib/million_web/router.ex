defmodule MillionWeb.Router do
  use MillionWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MillionWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", MillionWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/counter", CounterLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", MillionWeb do
  #   pipe_through :api
  # end
end
