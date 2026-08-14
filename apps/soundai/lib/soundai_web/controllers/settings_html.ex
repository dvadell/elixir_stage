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
  # browser engine is the last option.
  #
  # NOTE: onnx-community/Supertonic-TTS-2-ONNX was evaluated (T0008) and
  # removed: it requires engine-specific speaker_embeddings parameter that
  # breaks the generic text-to-speech pipeline interface, has 3.1x slower
  # cold load (26s vs 8s), and 7x larger download (260MB vs 38MB).
  @tts_models [
    {
      "Xenova/mms-tts-spa",
      gettext("MMS Español — balanced"),
      gettext(
        "Local Spanish TTS model (VITS). Runs in the browser after first download. No audio leaves your device."
      )
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
