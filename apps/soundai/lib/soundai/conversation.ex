defmodule Soundai.Conversation do
  @moduledoc """
  Entry point for transcripts produced by the browser-side Whisper STT.

  The controller hands transcribed text to `submit_transcript/3`. It validates
  the input, loads (or creates) the per-conversation LLM context from
  `Soundai.Conversation.Store`, relays the text to the LLM through an injectable
  adapter (`Soundai.Conversation.LLM` by default), persists the updated context,
  and returns the LLM reply.

  The system prompt stays exactly as configured. Dynamic context rides in the
  **last message** instead, prefixed to the transcript: the browser's own local
  date and time (the clock never depends on the server), when shared the user's
  approximate geolocation, and the notes saved through `/notes`
  (`Soundai.Notes`). Invalid values are dropped silently.

  Configuration lives under `config :soundai, Soundai.Conversation`:

    * `:system_prompt` — system prompt for new conversations (default: a Spanish
      voice-assistant prompt).
    * `:llm_timeout_ms` — how long to wait for the LLM reply (default: 30 s).
    * `:max_response_chars` — cap on the returned text (default: 2000), so TTS
      latency stays sane. Over-long replies are cut at the cap and a closing
      note is appended. Before capping, replies are
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
  alias Soundai.Notes

  @max_text_length 4000
  @truncation_note "Hay más para hablar de este tema, pero el texto se volvió muy largo. Me detendré acá"

  @default_system_prompt """
  Eres un asistente de voz amable y directo. Respondes en español, de forma breve y natural, como en una conversación hablada.

  El texto que recibes proviene de un reconocimiento de voz que a veces comete errores: puede partir o unir palabras, y malinterpretar sonidos parecidos. Haz tu mejor esfuerzo por deducir la intención real del mensaje y responde a ella, sin pedir aclaraciones ni corregir al usuario.

  Responde con frases cortas y sencillas, con palabras comunes y fáciles de pronunciar y de sintetizar por voz. No uses listas ni encabezados.
  """

  @days ~W(lunes martes miércoles jueves viernes sábado domingo)
  @months ~W(enero febrero marzo abril mayo junio julio agosto septiembre octubre noviembre diciembre)

  @type meta :: %{
          optional(:latitude) => number() | nil,
          optional(:longitude) => number() | nil,
          optional(:timezone) => String.t() | nil,
          optional(:date) => String.t() | nil,
          optional(:time) => String.t() | nil
        }

  @doc """
  Validates and relays a transcribed utterance to the LLM.

  `meta` carries optional client context relayed to the LLM inside the last
  message: `:date` / `:time` (the browser's local wall clock, `"YYYY-MM-DD"` /
  `"HH:MM:SS"`), `:timezone` (IANA name, informational label) and `:latitude` /
  `:longitude` (browser geolocation, degrees). Invalid values are ignored
  silently.

  ## Returns

    * `{:ok, response, conversation_id}` — LLM reply plus the (persisted)
      conversation id, usable on the next turn.
    * `{:error, :empty}` / `{:error, :too_long}` / `{:error, :invalid}` —
      validation failures.
    * `{:error, :llm_unavailable}` / `{:error, :llm_timeout}` — LLM failures.
  """
  def submit_transcript(text, conversation_id \\ nil, meta \\ %{})

  def submit_transcript(text, conversation_id, meta) when is_binary(text) and is_map(meta) do
    text = String.trim(text)

    case validate(text) do
      :ok -> do_submit(text, conversation_id, meta)
      error -> error
    end
  end

  def submit_transcript(_text, _conversation_id, _meta), do: {:error, :invalid}

  defp do_submit(text, conversation_id, meta) do
    {id, context} = Store.get_or_new(conversation_id, system_prompt())

    case llm_call(build_message(text, meta), context) do
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
    max_chars = config(:max_response_chars, 2000)

    if String.length(response) > max_chars do
      String.slice(response, 0, max_chars) <> " " <> @truncation_note
    else
      response
    end
  end

  defp cap_response_length(response), do: response

  defp system_prompt, do: config(:system_prompt, @default_system_prompt)

  # ------------------------------------------------------------- last message

  # The transcript prefixed with a bracketed context block (browser-supplied
  # date/time, optional user location and the saved notes). The system prompt
  # is never touched: the blocks travel inside this one message only.
  defp build_message(text, meta) do
    iodata =
      case context_lines(meta) do
        [] ->
          [notes_block(), text]

        lines ->
          [["[", Enum.intersperse(lines, " "), "]\n\n"], notes_block(), text]
      end

    IO.iodata_to_binary(iodata)
  end

  defp context_lines(meta) do
    Enum.reject([datetime_line(meta), location_line(meta)], &is_nil/1)
  end

  # Bracketed block with the user's note — one big, freely editable text
  # maintained through /notes — so the LLM can answer questions about it;
  # `[]` when there is none. It is included verbatim and uncapped. A database
  # failure never breaks the conversation path: it is logged and the message
  # simply goes out without notes.
  defp notes_block do
    case prompt_notes() do
      {:ok, text} when is_binary(text) ->
        ["[Notas del usuario:\n", text, "]\n\n"]

      _no_note_or_error ->
        []
    end
  end

  # Reading the note is best-effort: the rescue is intentionally broad because
  # a voice turn must never crash over missing notes. That also masks
  # non-database bugs here, so failures are always logged at warning level.
  defp prompt_notes do
    {:ok, Notes.note_text()}
  rescue
    exception ->
      Logger.warning("Could not load notes for the LLM message: #{Exception.message(exception)}")
      {:error, exception}
  end

  # "Fecha y hora actual: viernes 22 de agosto de 2026, 14:35 (Europe/Madrid)."
  # Both values come straight from the browser's clock (`date` "YYYY-MM-DD",
  # `time` "HH:MM:SS"); anything that does not parse as ISO date/time is
  # dropped and the message goes through untouched.
  defp datetime_line(meta) do
    with {:ok, date} <- parse_date(meta[:date]),
         {:ok, clock} <- parse_time(meta[:time]) do
      time = Calendar.strftime(clock, "%H:%M")

      "Fecha y hora actual: #{day_name(Date.day_of_week(date))} #{date.day} de " <>
        "#{month_name(date.month)} de #{date.year}, #{time}#{zone_label(meta[:timezone])}."
    else
      _ -> nil
    end
  end

  defp parse_date(date) when is_binary(date), do: Date.from_iso8601(date)
  defp parse_date(_other), do: :error

  defp parse_time(time) when is_binary(time), do: Time.from_iso8601(time)
  defp parse_time(_other), do: :error

  # Informational label; restricted to IANA-zone-shaped strings so nothing
  # else can sneak into the prompt through it.
  defp zone_label(tz) when is_binary(tz) and byte_size(tz) <= 64 do
    if Regex.match?(~r|^[A-Za-z0-9_+\-/]+$|, tz), do: " (#{tz})", else: ""
  end

  defp zone_label(_other), do: ""

  defp day_name(index) when index in 1..7, do: Enum.at(@days, index - 1)
  defp month_name(index) when index in 1..12, do: Enum.at(@months, index - 1)

  defp location_line(meta) do
    with {lat, lon} <- coordinates(meta) do
      "Ubicación aproximada del usuario: latitud #{format_coord(lat)}, " <>
        "longitud #{format_coord(lon)} (coordenadas GPS)."
    end
  end

  # Geolocation is untrusted input from the browser: accept only numbers in
  # range; they are rendered rounded to four decimals (~11 m precision).
  defp coordinates(meta) do
    lat = number(meta[:latitude])
    lon = number(meta[:longitude])

    if lat != nil and lon != nil and lat >= -90 and lat <= 90 and lon >= -180 and lon <= 180 do
      {lat, lon}
    else
      nil
    end
  end

  defp number(n) when is_number(n), do: n * 1.0
  defp number(_other), do: nil

  defp format_coord(value) do
    value
    |> :erlang.float_to_binary(decimals: 4)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
    |> String.replace(".", ",")
  end

  # Test seam: tests inject a fake adapter (mirrors Soundai.TTS.adapter/0).
  defp adapter do
    config(:adapter) || LLM
  end

  defp config(key, default \\ nil) do
    Application.get_env(:soundai, __MODULE__, [])[key] || default
  end
end
