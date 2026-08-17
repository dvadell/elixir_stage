# The TTS endpoint is intentionally public (there is no authentication in the
# app yet), so skip the missing-authentication heuristic. Rate limiting must be
# introduced before any public deployment.
# credo:disable-for-this-file OeditusCredo.Check.Security.MissingAuthentication
defmodule SoundaiWeb.TTSController do
  use SoundaiWeb, :controller

  @doc """
  Synthesizes speech from `text` and returns it as a playable WAV.

  The client sends JSON (`{"text": "...", "language": "spanish"}`) and receives
  `audio/wav` bytes with `X-TTS-Duration-Ms` and `X-TTS-Model` headers. Text is
  validated and length-capped; it is never echoed back or logged in full.
  """
  def create(conn, %{"text" => text} = params) do
    case Soundai.TTS.synthesize(text, Map.get(params, "language")) do
      {:ok, %{audio: audio, content_type: content_type, duration_ms: duration_ms}} ->
        conn
        |> put_resp_header("content-type", content_type)
        |> put_resp_header("x-tts-duration-ms", "#{duration_ms}")
        |> put_resp_header("x-tts-model", "Xenova/mms-tts-spa")
        |> send_resp(200, audio)

      {:error, reason} when reason in [:empty, :too_long, :invalid] ->
        render_error(conn, :unprocessable_entity, text_error(reason))

      {:error, :not_ready} ->
        render_error(conn, :service_unavailable, "server TTS is not ready")

      {:error, _reason} ->
        render_error(conn, :internal_server_error, "synthesis failed")
    end
  end

  def create(conn, _params) do
    render_error(conn, :unprocessable_entity, "is required")
  end

  defp render_error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{errors: %{text: message}})
  end

  defp text_error(:empty), do: "can't be blank"
  defp text_error(:too_long), do: "is too long"
  defp text_error(:invalid), do: "is invalid"
end
