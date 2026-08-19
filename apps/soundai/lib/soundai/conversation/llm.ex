defmodule Soundai.Conversation.LLM do
  @moduledoc """
  Default LLM adapter: relays a message through `BranchedLLM.Chat.send_message/3`.

  Returns `{:ok, response, updated_context}` on success or `{:error, reason}`.
  Tests inject `Soundai.Conversation.LLM.FakeAdapter` through the `:adapter`
  config key instead (mirrors `Soundai.TTS`).
  """

  @doc """
  Calls the LLM with `text`, the conversation `context`, and `opts`
  (e.g. `:timeout`).
  """
  def call(text, context, opts) do
    BranchedLLM.Chat.send_message(text, context, opts)
  end
end
