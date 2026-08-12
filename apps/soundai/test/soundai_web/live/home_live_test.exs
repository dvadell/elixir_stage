defmodule SoundaiWeb.HomeLiveTest do
  use SoundaiWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  defp ready(view) do
    render_hook(view, "voice_state", %{"state" => "idle"})
    view
  end

  test "the model is preloaded before the record button is shown", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#model-loading")
    assert view |> element("#model-loading") |> render() =~ "Loading speech model…"
    refute has_element?(view, "#record-button")
  end

  test "shows download progress while preloading the model", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    render_hook(view, "voice_state", %{"state" => "loading", "progress" => 40})

    assert has_element?(view, "#model-loading-progress")
    assert render(view) =~ "Downloading: 40%"
  end

  test "the record button is shown once the model is ready", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    ready(view)

    refute has_element?(view, "#model-loading")
    assert has_element?(view, "#voice-assistant[phx-hook='VoiceAssistant']")
    assert has_element?(view, "#record-button")
    assert has_element?(view, "#record-button[type='button']")
    assert view |> element("#record-button") |> render() =~ "Hold to talk"
    refute has_element?(view, "#voice-transcript")
  end

  test "pressing the button surfaces the listening state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    ready(view)
    render_hook(view, "voice_state", %{"state" => "listening"})

    assert view |> element("#record-button") |> render() =~ "Listening…"
  end

  test "releasing surfaces the transcribing state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    ready(view)
    render_hook(view, "voice_state", %{"state" => "transcribing"})

    assert view |> element("#record-button") |> render() =~ "Transcribing…"
  end

  test "a successful transcription shows the transcript and keeps the UI usable", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    ready(view)

    render_hook(view, "voice_state", %{
      "state" => "result",
      "transcript" => "hola, soy tu asistente"
    })

    assert has_element?(view, "#voice-transcript")
    assert view |> element("#voice-transcript") |> render() =~ "hola, soy tu asistente"
    assert view |> element("#record-button") |> render() =~ "Tap to talk again"
  end

  test "a transcription error is surfaced without crashing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    ready(view)

    render_hook(view, "voice_state", %{
      "state" => "error",
      "error" => "Microphone access was denied."
    })

    assert view |> element("#record-button") |> render() =~ "Tap to retry"
    assert render(view) =~ "Microphone access was denied."
  end

  test "a failed preload surfaces an error and retrying reloads the model", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    render_hook(view, "voice_state", %{
      "state" => "error",
      "error" => "Model download failed."
    })

    assert view |> element("#record-button") |> render() =~ "Tap to retry"

    render_hook(view, "voice_state", %{"state" => "loading", "progress" => 0})
    assert has_element?(view, "#model-loading")

    ready(view)
    assert view |> element("#record-button") |> render() =~ "Hold to talk"
  end

  test "unknown voice states are ignored", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    render_hook(view, "voice_state", %{"state" => "nonsense"})

    assert has_element?(view, "#model-loading")
  end

  test "model download progress is shown only while preparing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    refute render(view) =~ "Preparing Whisper…"

    ready(view)
    render_hook(view, "voice_state", %{"state" => "listening", "progress" => 25})

    assert render(view) =~ "Preparing Whisper… 25%"
  end

  test "progress keeps updating while transcribing on first load", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    ready(view)
    render_hook(view, "voice_state", %{"state" => "transcribing", "progress" => 60})

    assert render(view) =~ "Preparing Whisper… 60%"

    render_hook(view, "voice_state", %{"state" => "transcribing", "progress" => 85})

    assert render(view) =~ "Preparing Whisper… 85%"
  end

  test "progress stored while listening lingers after release until transcription runs", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    ready(view)
    render_hook(view, "voice_state", %{"state" => "listening", "progress" => 10})
    render_hook(view, "voice_state", %{"state" => "transcribing"})

    assert render(view) =~ "Preparing Whisper… 10%"
  end

  test "the preparing hint disappears once the model is ready", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    ready(view)
    render_hook(view, "voice_state", %{"state" => "listening", "progress" => 99})
    render_hook(view, "voice_state", %{"state" => "listening", "progress" => 100})

    refute render(view) =~ "Preparing Whisper…"

    render_hook(view, "voice_state", %{
      "state" => "result",
      "transcript" => "listo, gracias"
    })

    assert render(view) =~ "listo, gracias"
    refute render(view) =~ "Preparing Whisper…"
  end
end
