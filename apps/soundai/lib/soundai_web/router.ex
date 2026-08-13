defmodule SoundaiWeb.Router do
  use SoundaiWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :put_root_layout, html: {SoundaiWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", SoundaiWeb do
    pipe_through :browser

    get "/", HomeController, :index
    get "/settings", SettingsController, :index
  end

  # Other scopes may use custom stacks.
  # scope "/api", SoundaiWeb do
  #   pipe_through :api
  # end
end
