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
    plug :fetch_cookies
  end

  scope "/", SoundaiWeb do
    pipe_through :browser

    get "/", HomeController, :index
    get "/settings", SettingsController, :index
  end

  # JSON API. Only a single endpoint for now: the voice assistant POSTs the
  # local Whisper transcript here so the backend can process/relay it. Raw
  # microphone audio never reaches the server.
  scope "/api", SoundaiWeb do
    pipe_through :api

    post "/transcriptions", TranscriptionController, :create
    post "/tts", TTSController, :create
    post "/conversations/audio", ConversationAudioController, :create
  end
end
