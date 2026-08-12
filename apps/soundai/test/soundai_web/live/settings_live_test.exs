defmodule SoundaiWeb.SettingsLiveTest do
  use SoundaiWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "the /settings page renders the STT model select", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings")

    assert html =~ "Speech-to-text settings"
    assert html =~ "stt-model"
  end

  test "the settings page renders without the default header", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    html = render(view)
    refute html =~ "Get Started"
    refute html =~ ">Website</a>"
  end

  test "offers the multilingual whisper models", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#stt-model option[value='onnx-community/whisper-tiny']")
    assert has_element?(view, "#stt-model option[value='onnx-community/whisper-base']")
    assert has_element?(view, "#stt-model option[value='onnx-community/whisper-small']")
  end

  test "the select reports the browser's current choice on mount", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    refute has_element?(view, "#stt-model-desc")

    render_hook(view, "model_loaded", %{"model" => "onnx-community/whisper-small"})

    assert has_element?(view, "#stt-model-desc")
  end

  test "saving a model confirms the selection", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    render_hook(view, "model_saved", %{"model" => "onnx-community/whisper-small"})

    assert has_element?(view, "#stt-saved")
    assert view |> element("#stt-saved") |> render() =~ "Whisper Small"
  end

  test "unknown models are ignored", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    render_hook(view, "model_saved", %{"model" => "nonexistent/model"})

    refute has_element?(view, "#stt-saved")
  end
end
