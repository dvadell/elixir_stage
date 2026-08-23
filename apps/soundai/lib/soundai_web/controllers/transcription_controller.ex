# The transcription endpoint is intentionally public (there is no authentication
# in the app yet), so skip the missing-authentication heuristic. Rate limiting
# must be introduced before any public deployment.
# credo:disable-for-this-file OeditusCredo.Check.Security.MissingAuthentication
defmodule SoundaiWeb.TranscriptionController do
  use SoundaiWeb, :controller

  alias Soundai.Conversation.Store
  alias SoundaiWeb.ConversationCookie

  @doc """
  Receives a transcript produced by the browser-side Whisper STT.

  Only the text travels over the network; raw microphone audio never leaves the
  browser. The transcript is relayed to the LLM via `Soundai.Conversation`, and
  the reply is returned with a `conversation_id` (also set as a cookie) so the
  next turn can keep context.
  """
  def create(conn, %{"text" => text} = params) do
    conversation_id = resolve_conversation_id(conn, params)

    case Soundai.Conversation.submit_transcript(text, conversation_id, client_meta(params)) do
      {:ok, response, id} ->
        conn
        |> ConversationCookie.put(id)
        |> put_status(:created)
        |> json(%{
          ok: true,
          response: response,
          conversation_id: id,
          language: Map.get(params, "language")
        })

      {:error, :llm_unavailable} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{errors: %{text: "LLM is unavailable"}})

      {:error, :llm_timeout} ->
        conn
        |> put_status(:gateway_timeout)
        |> json(%{errors: %{text: "LLM timed out"}})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{text: reason_message(reason)}})
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

  defp reason_message(:empty), do: "can't be blank"
  defp reason_message(:too_long), do: "is too long"
  defp reason_message(:invalid), do: "is invalid"
end
