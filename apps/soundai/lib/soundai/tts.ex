defmodule Soundai.TTS do
  @moduledoc """
  Server-side text-to-speech for `soundai`.

  Synthesizes Spanish speech in-process with ONNX Runtime via `Ortex`, running
  the same `Xenova/mms-tts-spa` VITS model the browser uses. Requests are
  serialized through `Soundai.TTS.OrtexServer`.

  There is no UX length limit here: `@max_text_length` is a large safety net
  that only stops unbounded synthesis on the serialized in-process worker.

  The service is **optional**: it is disabled (returns `{:error, :not_ready}`)
  unless a model path is configured and the ONNX file exists on disk.
  """

  @max_text_length 100_000
  @default_language "spanish"

  @doc """
  Returns the configured ONNX model path (absolute), or `nil` when server TTS is
  not configured. Relative paths are resolved against `soundai`'s `priv` dir.
  """
  def model_path do
    case Application.get_env(:soundai, __MODULE__, [])[:model_path] do
      nil -> nil
      path when is_binary(path) -> Path.expand(path, :code.priv_dir(:soundai))
    end
  end

  @doc "True when a model file exists and the Ortex server can synthesize."
  def enabled? do
    path = model_path()
    is_binary(path) and File.exists?(path)
  end

  @doc """
  Synthesizes `text` into a WAV map (`%{audio, content_type, duration_ms,
  sample_rate}`).

  ## Returns

    * `{:ok, wav_map}` — audio bytes plus metadata.
    * `{:error, :empty}` / `{:error, :too_long}` — validation failures.
    * `{:error, :not_ready}` — no model configured/loaded.
    * `{:error, reason}` — inference failure.
  """
  def synthesize(text, language \\ @default_language)

  def synthesize(text, _language) when is_binary(text) do
    with :ok <- validate_text(text),
         {:ok, wav} <- adapter().synthesize(text) do
      {:ok, Map.put(wav, :content_type, "audio/wav")}
    end
  end

  def synthesize(_text, _language), do: {:error, :invalid}

  @doc false
  def validate_text(text) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" -> {:error, :empty}
      byte_size(trimmed) > @max_text_length -> {:error, :too_long}
      true -> :ok
    end
  end

  def validate_text(_text), do: {:error, :invalid}

  # Test seam: controller tests inject a fake adapter that returns canned bytes.
  defp adapter do
    Application.get_env(:soundai, __MODULE__, [])[:adapter] || Soundai.TTS.OrtexServer
  end
end
