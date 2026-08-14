# The transcription endpoint is intentionally public (there is no authentication
# in the app yet), so skip the missing-authentication heuristic. Rate limiting
# must be introduced before any public deployment.
# credo:disable-for-this-file OeditusCredo.Check.Security.MissingAuthentication
defmodule SoundaiWeb.TranscriptionController do
  use SoundaiWeb, :controller

  @doc """
  Receives a transcript produced by the browser-side Whisper STT.

  Only the text travels over the network; raw microphone audio never leaves the
  browser. The response is a minimal JSON envelope (`{"ok": true}`) that a
  follow-up ticket extends with the LLM reply.
  """
  def create(conn, %{"text" => text} = params) do
    case Soundai.Conversation.submit_transcript(text) do
      {:ok, _text} ->
        conn
        |> put_status(:created)
        |> json(%{ok: true, language: Map.get(params, "language")})

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

  defp reason_message(:empty), do: "can't be blank"
  defp reason_message(:too_long), do: "is too long"
  defp reason_message(:invalid), do: "is invalid"
end
