defmodule SoundpanelWeb.PageController do
  use SoundpanelWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
