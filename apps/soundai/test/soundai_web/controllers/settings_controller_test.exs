defmodule SoundaiWeb.SettingsControllerTest do
  use SoundaiWeb.ConnCase, async: true

  test "renders the STT model select", %{conn: conn} do
    conn = get(conn, ~p"/settings")
    html = html_response(conn, 200)

    assert html =~ "Voice assistant settings"
    assert html =~ "id=\"stt-model\""
  end

  test "renders the TTS engine select", %{conn: conn} do
    conn = get(conn, ~p"/settings")
    html = html_response(conn, 200)

    assert html =~ "id=\"tts-model\""
    assert html =~ "Text-to-speech engine"
  end

  test "renders without the default header", %{conn: conn} do
    conn = get(conn, ~p"/settings")
    html = html_response(conn, 200)

    refute html =~ "Get Started"
    refute html =~ ">Website</a>"
  end

  test "offers the multilingual whisper models with client-side descriptions", %{conn: conn} do
    conn = get(conn, ~p"/settings")
    html = html_response(conn, 200)

    assert html =~ ~S|value="onnx-community/whisper-tiny"|
    assert html =~ ~S|value="onnx-community/whisper-base"|
    assert html =~ ~S|value="onnx-community/whisper-small"|
    assert html =~ "data-desc"
  end

  test "offers TTS engine options with native as last option", %{conn: conn} do
    conn = get(conn, ~p"/settings")
    html = html_response(conn, 200)

    assert html =~ ~S|value="Xenova/mms-tts-spa"|
    assert html =~ ~S|value="onnx-community/Supertonic-TTS-2-ONNX"|
    assert html =~ ~S|value="native"|
    assert html =~ "data-desc"
  end

  test "links back to the voice assistant", %{conn: conn} do
    conn = get(conn, ~p"/settings")
    html = html_response(conn, 200)

    assert html =~ ~S|href="/"|
    assert html =~ "Back to the voice assistant"
  end
end
