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

  embed_templates "settings_html/*"

  defp models, do: @models
end
