defmodule SoundpanelWeb.PageController do
  use SoundpanelWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/soundboard.html")
  end
end
