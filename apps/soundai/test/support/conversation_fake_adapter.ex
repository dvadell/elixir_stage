defmodule Soundai.Conversation.LLM.FakeAdapter do
  @moduledoc """
  Test double for the `Soundai.Conversation.LLM` adapter seam (see
  `Soundai.Conversation.adapter/0`).

  Appends the user and assistant turns to the incoming context (mirroring what
  `BranchedLLM.Chat.send_message/3` returns) so context carry-over is exercised
  through the real `Soundai.Conversation.Store` path. When configured with
  `fake_capture_pid`, the incoming context is sent to that pid as
  `{:fake_llm_called, context}` so tests can assert what the adapter received.
  Configure `fake_error` to force `{:error, reason}` responses.
  """

  import ReqLLM.Context

  alias ReqLLM.Context

  @response "Respuesta simulada"

  def call(text, context, _opts) do
    case config()[:fake_error] do
      nil -> respond(text, context)
      error -> {:error, error}
    end
  end

  defp respond(text, context) do
    new_context =
      context
      |> Context.append(user(text))
      |> Context.append(assistant(@response))

    if pid = config()[:fake_capture_pid] do
      send(pid, {:fake_llm_called, context})
    end

    {:ok, @response, new_context}
  end

  defp config do
    Application.get_env(:soundai, Soundai.Conversation, [])
  end
end
