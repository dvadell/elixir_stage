# The audio conversation endpoint is intentionally public (there is no
# authentication in the app yet), so skip the missing-authentication heuristic.
# Rate limiting must be introduced before any public deployment.
# credo:disable-for-this-file OeditusCredo.Check.Security.MissingAuthentication
defmodule SoundaiWeb.ConversationAudioController do
  use SoundaiWeb, :controller

  alias Soundai.Conversation.Store
  alias SoundaiWeb.ConversationCookie

  @default_language "spanish"

  @doc """
  Runs the full voice round trip: the LLM (via `Soundai.Conversation`, the same
  seam as `POST /api/transcriptions`) answers the transcript, and the in-process
  TTS synthesizes that answer into a WAV played by the browser.

  The client sends JSON (`{"text": "...", "language": "spanish"}`) and receives
  `audio/wav` bytes with `X-Conversation-Id`, `X-TTS-Duration-Ms` and
  `X-TTS-Model` headers, plus `Set-Cookie: soundai_conversation` so the next turn
  keeps context.

  Failure is graceful and never a 500 for expected cases: LLM failures map to
  502/504, an absent TTS model to 503, and validation to 422. When the LLM
  succeeded but TTS did not, the error body carries the LLM `response` text so
  the client can fall back to speaking it with the native engine.
  """
  def create(conn, %{"text" => text} = params) do
    conversation_id = resolve_conversation_id(conn, params)
    language = Map.get(params, "language", @default_language)

    case Soundai.Conversation.submit_transcript(text, conversation_id, client_meta(params)) do
      {:ok, response, id} ->
        synthesize(conn, response, id, language)

      {:error, :llm_unavailable} ->
        render_llm_error(conn, :bad_gateway, "LLM is unavailable")

      {:error, :llm_timeout} ->
        render_llm_error(conn, :gateway_timeout, "LLM timed out")

      {:error, reason} ->
        render_validation_error(conn, reason)
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{text: "is required"}})
  end

  # `reset: true` starts a fresh conversation: the stored context (if any) for
  # the incoming id is deleted and a brand-new id is returned, replacing the
  # stale cookie. Clients that can clear the cookie themselves don't need it.
  defp resolve_conversation_id(conn, params) do
    if Map.get(params, "reset") in [true, "true", "1"] do
      stale = Map.get(params, "conversation_id") || conn.cookies[ConversationCookie.name()]

      if is_binary(stale) do
        Store.delete(stale)
      end

      nil
    else
      Map.get(params, "conversation_id") || conn.cookies[ConversationCookie.name()]
    end
  end

  # Optional client context relayed to the LLM inside the last message: the
  # browser's local date/time and timezone, plus geolocation when permitted.
  # `Soundai.Conversation` re-validates every value, so anything unexpected is
  # simply ignored downstream.
  defp client_meta(params) do
    %{
      date: params["date"],
      time: params["time"],
      timezone: params["timezone"],
      latitude: params["latitude"],
      longitude: params["longitude"]
    }
  end

  defp synthesize(conn, response, id, language) do
    # The conversation already advanced on the server (context persisted), so the
    # id is offered back via cookie and body on every TTS outcome.
    conn = ConversationCookie.put(conn, id)

    case Soundai.TTS.synthesize(response, language) do
      {:ok, %{audio: audio, content_type: content_type, duration_ms: duration_ms}} ->
        conn
        |> put_resp_header("content-type", content_type)
        |> put_resp_header("x-conversation-id", id)
        |> put_resp_header("x-tts-duration-ms", "#{duration_ms}")
        |> put_resp_header("x-tts-model", "Xenova/mms-tts-spa")
        |> send_resp(200, audio)

      {:error, :not_ready} ->
        render_tts_error(conn, :service_unavailable, "server TTS is not ready", response, id)

      {:error, reason} when reason in [:empty, :too_long, :invalid] ->
        render_tts_error(conn, :unprocessable_entity, text_error(reason), response, id)

      {:error, _reason} ->
        render_tts_error(conn, :internal_server_error, "synthesis failed", response, id)
    end
  end

  defp render_llm_error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{errors: %{text: message}})
  end

  defp render_validation_error(conn, reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{text: text_error(reason)}})
  end

  defp render_tts_error(conn, status, message, response, id) do
    conn
    |> put_status(status)
    |> json(%{errors: %{text: message}, response: response, conversation_id: id})
  end

  defp text_error(:empty), do: "can't be blank"
  defp text_error(:too_long), do: "is too long"
  defp text_error(:invalid), do: "is invalid"
end
