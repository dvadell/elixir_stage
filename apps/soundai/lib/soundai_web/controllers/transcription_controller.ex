# The transcription endpoint is intentionally public (there is no authentication
# in the app yet), so skip the missing-authentication heuristic. Rate limiting
# must be introduced before any public deployment.
# credo:disable-for-this-file OeditusCredo.Check.Security.MissingAuthentication
defmodule SoundaiWeb.TranscriptionController do
  use SoundaiWeb, :controller

  @cookie_name "soundai_conversation"
  @cookie_max_age 60 * 60 * 24 * 7

  @doc """
  Receives a transcript produced by the browser-side Whisper STT.

  Only the text travels over the network; raw microphone audio never leaves the
  browser. The transcript is relayed to the LLM via `Soundai.Conversation`, and
  the reply is returned with a `conversation_id` (also set as a cookie) so the
  next turn can keep context.
  """
  def create(conn, %{"text" => text} = params) do
    conversation_id = Map.get(params, "conversation_id") || conn.cookies[@cookie_name]

    case Soundai.Conversation.submit_transcript(text, conversation_id) do
      {:ok, response, id} ->
        conn
        |> put_resp_cookie(@cookie_name, id,
          max_age: @cookie_max_age,
          path: "/",
          same_site: "Lax"
        )
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

  defp reason_message(:empty), do: "can't be blank"
  defp reason_message(:too_long), do: "is too long"
  defp reason_message(:invalid), do: "is invalid"
end
