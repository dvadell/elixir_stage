defmodule SoundpanelWeb.PageControllerTest do
  use SoundpanelWeb.ConnCase

  test "GET / redirects to the soundboard", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/soundboard.html"
  end
end
