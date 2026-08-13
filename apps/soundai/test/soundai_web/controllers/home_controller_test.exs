defmodule SoundaiWeb.HomeControllerTest do
  use SoundaiWeb.ConnCase, async: true

  test "renders the voice assistant shell", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert html_response(conn, 200)
    assert conn.resp_body =~ "id=\"voice-assistant\""
    assert conn.resp_body =~ "data-voice-assistant"
  end

  test "renders the model loading and record UI states", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "id=\"model-loading\""
    assert html =~ "Loading speech model…"
    assert html =~ "id=\"record-button\""
    assert html =~ "Hold to record"
    assert html =~ "id=\"model-loading-progress\""
    assert html =~ "id=\"preparing-hint\""
  end

  test "links to the settings page", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ ~S|href="/settings"|
    assert html =~ "Speech-to-text settings"
  end

  test "renders the transcript box", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "id=\"voice-result\""
    assert html =~ "id=\"voice-transcript\""
    assert html =~ "id=\"voice-error\""
  end
end
