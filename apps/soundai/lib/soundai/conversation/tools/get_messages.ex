defmodule Soundai.Conversation.Tools.GetMessages do
  @max_played 5

  @moduledoc """
  LLM tool: plays the pending messages of the shared family answering machine
  (`Soundai.Messages`).

  `tool/0` builds the `ReqLLM.Tool` handed to the LLM. Without filters it
  reads *all* pending messages (press play on the tape); optional `from`/`to`
  narrow the playback when the user names someone ("dime el mensaje de
  Diego"). The callback marks the played messages delivered and returns a
  ready-to-speak Spanish script — the assistant repeats it verbatim, no
  rephrasing needed.

  Playback is bounded: at most #{@max_played} messages per call, oldest first,
  with a "…y queda(n) N más" tail; the rest stay pending for the next ask.
  Played messages are stamped delivered, but they stay replayable for a short
  grace window (`Soundai.Messages` `:delivery_grace_seconds`): a play that
  never reached the speaker (lost tool result, double call) is read again on
  the next ask instead of being silently consumed. Strictly pending messages
  always take precedence — asking again right after a playback advances the
  tape. Failures return `{:error, reason}` so `branched_llm` injects the error
  into the conversation context and the LLM can apologize in plain words.
  """

  require Logger

  alias Soundai.Messages

  @doc """
  Builds the `get_messages` tool for the LLM.
  """
  @spec tool() :: ReqLLM.Tool.t()
  def tool do
    ReqLLM.Tool.new!(
      name: "get_messages",
      description:
        "Lee en voz alta los mensajes nuevos del contestador familiar. Úsala cuando el " <>
          "usuario pregunte si tiene mensajes o pida escucharlos («¿Tengo algún mensaje?», " <>
          "«Dime el mensaje de Diego»). Sin filtros lee todos los mensajes nuevos. Pasa " <>
          "'from' solo si piden los mensajes dejados por alguien concreto y 'to' solo si los " <>
          "piden para alguien concreto (quien pregunta). Repite el resultado tal cual, que " <>
          "ya está redactado para ser hablado.",
      parameter_schema: %{
        type: "object",
        properties: %{
          from: %{
            type: "string",
            description:
              "Nombre de la persona que dejó los mensajes, solo si el usuario lo mencionó"
          },
          to: %{
            type: "string",
            description:
              "Nombre de la persona destinataria, solo si el usuario lo mencionó (normalmente quien pregunta)"
          }
        },
        required: []
      },
      callback: &get_messages/1
    )
  end

  @doc """
  Tool callback: returns `{:ok, script}` with the pending messages phrased for
  speech (marking them delivered), or `{:error, reason}` when the database
  fails.
  """
  def get_messages(args) do
    opts = [from: opt(args, "from"), to: opt(args, "to")]

    with {:ok, pending} <- fetch_pending(opts) do
      {to_play, remaining} = Enum.split(pending, @max_played)

      case to_play do
        [] ->
          {:ok, empty_text(opts)}

        messages ->
          mark_played(messages)
          {:ok, script(messages, remaining)}
      end
    end
  end

  # A database failure must surface as an error result, never a crash: the LLM
  # turns it into a spoken apology.
  defp fetch_pending(opts) do
    {:ok, Messages.pending_messages(opts)}
  rescue
    exception ->
      Logger.warning("Could not load messages for playback: #{Exception.message(exception)}")
      {:error, "could not access the messages"}
  end

  # Delivery stamping is best-effort by design: the user has already heard the
  # messages, so a failure only means they replay on the next ask. It is
  # logged and otherwise ignored (:ok makes that explicit for callers).
  defp mark_played(messages) do
    Messages.mark_delivered(messages)
  rescue
    exception ->
      Logger.warning("Could not mark messages as delivered: #{Exception.message(exception)}")
      :ok
  end

  # A blank filter string is an absent filter: the LLM sometimes sends "" when
  # the user named nobody.
  defp opt(args, key) do
    case args[key] do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _other ->
        nil
    end
  end

  # ------------------------------------------------------------------ script

  defp empty_text(opts) do
    case named_filters(opts) do
      [] -> "No tienes mensajes nuevos."
      parts -> "No hay mensajes nuevos #{Enum.join(parts, " ")}."
    end
  end

  defp script(messages, remaining) do
    count = length(messages)
    intro = "Tienes #{count_message(count)} nuevo#{plural(count)}"
    body = Enum.map_join(messages, " ", &entry/1)
    tail = remaining_tail(remaining)

    "#{intro}. #{body}#{tail}"
  end

  defp count_message(1), do: "un mensaje"
  defp count_message(count), do: "#{count} mensajes"

  defp plural(1), do: ""
  defp plural(_count), do: "s"

  # "de Diego: no te olvides de tomar agua hoy." / "de alguien: …"
  defp entry(message) do
    from = message.from_name || "alguien"
    "De #{from}: #{message.body}"
  end

  defp remaining_tail([]), do: ""

  defp remaining_tail(remaining) do
    count = length(remaining)
    verb = if count == 1, do: "Queda", else: "Quedan"

    " #{verb} #{count} mensaje#{plural(count)} más."
  end

  defp named_filters(opts) do
    []
    |> maybe_add(:from, opts[:from])
    |> maybe_add(:to, opts[:to])
  end

  defp maybe_add(parts, :from, name) when is_binary(name),
    do: List.insert_at(parts, 0, "de #{String.trim(name)}")

  defp maybe_add(parts, :to, name) when is_binary(name),
    do: parts ++ ["para #{String.trim(name)}"]

  defp maybe_add(parts, _key, _name), do: parts
end
