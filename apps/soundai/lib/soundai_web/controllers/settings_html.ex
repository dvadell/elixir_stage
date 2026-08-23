defmodule SoundaiWeb.SettingsHTML do
  use SoundaiWeb, :html

  # Multilingual Whisper exports from the onnx-community org, all with
  # transformers.js support and Spanish capability. Extend freely; the voice
  # assistant reads the selection from the browser cookie and falls back to
  # the committed WHISPER_CONFIG defaults when nothing has been chosen.
  @models [
    {
      "onnx-community/whisper-tiny",
      gettext("Whisper Tiny — el más rápido"),
      gettext(
        "El más rápido y ligero, con la menor precisión. Ideal para frases muy cortas o dispositivos lentos."
      )
    },
    {
      "onnx-community/whisper-base",
      gettext("Whisper Base — equilibrado"),
      gettext(
        "Buena precisión y velocidad. Es el predeterminado; funciona bien en la mayoría de los dispositivos."
      )
    },
    {
      "onnx-community/whisper-small",
      gettext("Whisper Small — el mejor en español"),
      gettext(
        "La mejor precisión, notablemente mejor en español, pero más lento y con una descarga más grande."
      )
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
      gettext("MMS Español — equilibrado"),
      gettext(
        "Modelo local de texto a voz en español (VITS). Funciona en el navegador tras la primera descarga. Ningún audio sale de tu dispositivo."
      )
    },
    {
      "server",
      gettext("Servidor (respuesta de voz)"),
      gettext(
        "El servidor responde por voz: el LLM y la síntesis ocurren en una sola llamada (respuesta de audio). Nada que descargar; requiere conexión y modelo de TTS instalado en el servidor."
      )
    },
    {
      "native",
      gettext("Voz nativa del sistema"),
      gettext(
        "Las voces integradas de tu navegador. No requiere descarga. La calidad varía según el sistema operativo."
      )
    }
  ]

  embed_templates "settings_html/*"

  defp models, do: @models
  defp tts_models, do: @tts_models
end
