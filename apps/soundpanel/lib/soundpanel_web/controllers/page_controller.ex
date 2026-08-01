defmodule SoundpanelWeb.PageController do
  use SoundpanelWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: "/soundboard.html")
  end
end
