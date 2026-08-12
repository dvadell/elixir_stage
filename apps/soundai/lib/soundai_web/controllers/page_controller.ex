defmodule SoundaiWeb.PageController do
  use SoundaiWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
