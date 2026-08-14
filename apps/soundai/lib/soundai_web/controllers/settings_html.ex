defmodule SoundaiWeb.SettingsHTML do
  use SoundaiWeb, :html

  # Multilingual Whisper exports from the onnx-community org, all with
  # transformers.js support and Spanish capability. Extend freely; the voice
  # assistant reads the selection from the browser cookie and falls back to
  # the committed WHISPER_CONFIG defaults when nothing has been chosen.
  @models [
    {
      "onnx-community/whisper-tiny",
      gettext("Whisper Tiny — fastest"),
      gettext(
        "Fastest and lightest, lowest accuracy. Best for very short utterances or slow devices."
      )
    },
    {
      "onnx-community/whisper-base",
      gettext("Whisper Base — balanced"),
      gettext("Good accuracy and speed. The default; works well on most devices.")
    },
    {
      "onnx-community/whisper-small",
      gettext("Whisper Small — best Spanish"),
      gettext("Best accuracy, noticeably better Spanish, but slower and a larger download.")
    }
  ]

  # TTS engine options. Local model options are listed first; the native
  # browser engine is the last option. Until local engines are implemented
  # (T0007), unimplemented ids fall back to the native engine via the
  # registry in tts_engine.js.
  @tts_models [
    {
      "Xenova/mms-tts-spa",
      gettext("MMS Español — balanced"),
      gettext(
        "Local Spanish TTS model (VITS). Runs in the browser after first download. No audio leaves your device."
      )
    },
    {
      "onnx-community/Supertonic-TTS-2-ONNX",
      gettext("Supertonic 2 — best quality"),
      gettext("Higher quality local TTS model. Larger download, slower inference. Experimental.")
    },
    {
      "native",
      gettext("Voz nativa del sistema"),
      gettext(
        "Your browser's built-in voices. No download required. Quality varies by operating system."
      )
    }
  ]

  embed_templates "settings_html/*"

  defp models, do: @models
  defp tts_models, do: @tts_models
end
