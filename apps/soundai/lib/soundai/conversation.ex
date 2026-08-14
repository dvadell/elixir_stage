defmodule Soundai.Conversation do
  @moduledoc """
  Entry point for transcripts produced by the browser-side Whisper STT.

  The controller hands transcribed text to `submit_transcript/1` and nothing
  else. Today the transcript is normalized and echoed back as the `response`
  field; the follow-up LLM relay (through Needle) is added inside this function
  without touching the web layer.
  """

  require Logger

  @max_text_length 4000

  @doc """
  Validates and receives a transcribed utterance.

  Returns `{:ok, text}` when the transcript is acceptable (the browser can
  expect a `201 {"ok": true}`), or `{:error, reason}` with a terse reason that
  maps to a 422. `text` is untrusted user input and is bounded in length.
  """
  def submit_transcript(text) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" ->
        {:error, :empty}

      String.length(text) > @max_text_length ->
        {:error, :too_long}

      true ->
        Logger.info("received transcript (len=#{String.length(text)})")
        {:ok, text}
    end
  end

  def submit_transcript(_other), do: {:error, :invalid}
end
