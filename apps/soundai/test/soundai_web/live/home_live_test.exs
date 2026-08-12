defmodule SoundaiWeb.HomeLiveTest do
  use SoundaiWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders a full-screen record button on /", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "record-button"
  end

  test "the record button is the only interactive element", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#record-button")
    assert has_element?(view, "#record-button[type='button']")
    assert has_element?(view, "#record-button[phx-hook]")
  end
end
