# The settings page is intentionally public (there is no authentication in
# the app yet), so skip the missing-authentication heuristic.
# credo:disable-for-this-file OeditusCredo.Check.Security.MissingAuthentication
defmodule SoundaiWeb.SettingsController do
  use SoundaiWeb, :controller

  # The settings page is public and stateless: every visitor may choose their
  # own STT model preference. The selection is persisted in a browser cookie
  # entirely on the client, so this page (like the voice assistant) keeps
  # working offline once the app shell is cached.
  def index(conn, _params) do
    render(conn, :index)
  end
end
