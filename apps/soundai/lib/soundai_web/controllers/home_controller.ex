# The voice assistant page is intentionally public (there is no authentication
# in the app yet), so skip the missing-authentication heuristic.
# credo:disable-for-this-file OeditusCredo.Check.Security.MissingAuthentication
defmodule SoundaiWeb.HomeController do
  use SoundaiWeb, :controller

  # The voice assistant page is fully client-side and offline-first: the
  # server only renders the HTML shell. Every interaction (microphone,
  # Whisper transcription, UI state) is driven from the browser, so the page
  # keeps working when the network is unavailable as long as the app shell
  # and the speech model are already loaded/cached.
  def index(conn, _params) do
    render(conn, :index)
  end
end
