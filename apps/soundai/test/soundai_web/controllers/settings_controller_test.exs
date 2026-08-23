defmodule SoundaiWeb.SettingsControllerTest do
  use SoundaiWeb.ConnCase, async: true

  test "renders the STT model select", %{conn: conn} do
    conn = get(conn, ~p"/settings")
    html = html_response(conn, 200)

    assert html =~ "Ajustes del asistente de voz"
    assert html =~ "id=\"stt-model\""
  end

  test "renders the TTS engine select", %{conn: conn} do
    conn = get(conn, ~p"/settings")
    html = html_response(conn, 200)

    assert html =~ "id=\"tts-model\""
    assert html =~ "Motor de texto a voz"
  end

  test "renders without the default header", %{conn: conn} do
    conn = get(conn, ~p"/settings")
    html = html_response(conn, 200)

    refute html =~ "Get Started"
    refute html =~ ">Website</a>"
    refute html =~ ">Sitio web</a>"
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
    assert html =~ ~S|value="server"|
    assert html =~ ~S|value="native"|
    assert html =~ "data-desc"
    # native stays the last (fallback) option, after the server engine
    server_at = html |> String.split(~S|value="server"|) |> hd() |> String.length()
    native_at = html |> String.split(~S|value="native"|) |> hd() |> String.length()
    assert server_at < native_at
    # Supertonic-TTS-2-ONNX was removed (T0008): requires engine-specific
    # speaker_embeddings, 3.1x slower cold load, 7x larger download
    refute html =~ ~S|value="onnx-community/Supertonic-TTS-2-ONNX"|
  end

  test "links back to the voice assistant", %{conn: conn} do
    conn = get(conn, ~p"/settings")
    html = html_response(conn, 200)

    assert html =~ ~S|href="/"|
    assert html =~ "Volver al asistente de voz"
  end
end
