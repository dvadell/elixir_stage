defmodule Soundai.Conversation do
  @moduledoc """
  Entry point for transcripts produced by the browser-side Whisper STT.

  The controller hands transcribed text to `submit_transcript/2`. It validates
  the input, loads (or creates) the per-conversation LLM context from
  `Soundai.Conversation.Store`, relays the text to the LLM through an injectable
  adapter (`Soundai.Conversation.LLM` by default), persists the updated context,
  and returns the LLM reply.

  Configuration lives under `config :soundai, Soundai.Conversation`:

    * `:system_prompt` — system prompt for new conversations (default: a Spanish
      voice-assistant prompt).
    * `:llm_timeout_ms` — how long to wait for the LLM reply (default: 30 s).
    * `:max_response_chars` — cap on the returned text, with a trailing "…"
      (default: 500), so TTS latency stays sane. Before capping, replies are
      run through `Soundai.Conversation.SpeechText.clean/1` so Markdown
      decoration and emoji never reach the TTS engine.
    * `:store_ttl_ms` — idle TTL for conversations (default: 30 min).
    * `:adapter` — LLM adapter module (tests inject a fake).
    * `:llm_tools` — modules exposing `tool/0` (a `ReqLLM.Tool`) handed to the
      LLM on every turn; empty list disables tools. Default: weather tool.

  Errors are never raised: LLM failures map to `:llm_unavailable` / `:llm_timeout`.
  """

  require Logger

  alias Soundai.Conversation.{LLM, SpeechText, Store, Tools.Weather}

  @max_text_length 4000

  @default_system_prompt """
  Eres un asistente de voz amable y directo. Respondes en español, de forma breve y natural, como en una conversación hablada.

  El texto que recibes proviene de un reconocimiento de voz que a veces comete errores: puede partir o unir palabras, y malinterpretar sonidos parecidos. Haz tu mejor esfuerzo por deducir la intención real del mensaje y responde a ella, sin pedir aclaraciones ni corregir al usuario.

  Responde con frases cortas y sencillas, con palabras comunes y fáciles de pronunciar y de sintetizar por voz. No uses listas ni encabezados.
  """

  @doc """
  Validates and relays a transcribed utterance to the LLM.

  ## Returns

    * `{:ok, response, conversation_id}` — LLM reply plus the (persisted)
      conversation id, usable on the next turn.
    * `{:error, :empty}` / `{:error, :too_long}` / `{:error, :invalid}` —
      validation failures.
    * `{:error, :llm_unavailable}` / `{:error, :llm_timeout}` — LLM failures.
  """
  def submit_transcript(text, conversation_id \\ nil)

  def submit_transcript(text, conversation_id) when is_binary(text) do
    text = String.trim(text)

    case validate(text) do
      :ok -> do_submit(text, conversation_id)
      error -> error
    end
  end

  def submit_transcript(_text, _conversation_id), do: {:error, :invalid}

  defp do_submit(text, conversation_id) do
    {id, context} = Store.get_or_new(conversation_id, system_prompt())

    case llm_call(text, context) do
      {:ok, response, new_context} ->
        Logger.info("LLM response for conversation=#{id}: #{inspect(response)}")
        Store.put(id, new_context)
        {:ok, response |> SpeechText.clean() |> cap_response_length(), id}

      {:error, reason} ->
        Logger.warning("LLM call failed for conversation=#{id}: #{inspect(reason)}")
        {:error, map_llm_error(reason)}
    end
  end

  defp validate(text) do
    cond do
      text == "" -> {:error, :empty}
      byte_size(text) > @max_text_length -> {:error, :too_long}
      true -> :ok
    end
  end

  defp llm_call(text, context) do
    opts = [timeout: config(:llm_timeout_ms, 30_000), tools: tools()]
    adapter().call(text, context, opts)
  end

  defp tools do
    config(:llm_tools, [Weather])
    |> Enum.map(& &1.tool())
  end

  defp map_llm_error(reason) when is_binary(reason) do
    if reason =~ "Timed out" do
      :llm_timeout
    else
      :llm_unavailable
    end
  end

  defp map_llm_error(_reason), do: :llm_unavailable

  defp cap_response_length(response) when is_binary(response) do
    max_chars = config(:max_response_chars, 500)

    if String.length(response) > max_chars do
      String.slice(response, 0, max_chars) <> "…"
    else
      response
    end
  end

  defp cap_response_length(response), do: response

  defp system_prompt, do: config(:system_prompt, @default_system_prompt)

  # Test seam: tests inject a fake adapter (mirrors Soundai.TTS.adapter/0).
  defp adapter do
    config(:adapter) || LLM
  end

  defp config(key, default \\ nil) do
    Application.get_env(:soundai, __MODULE__, [])[key] || default
  end
end
