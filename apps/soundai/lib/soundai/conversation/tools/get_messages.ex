defmodule Soundai.Conversation.Tools.GetMessages do
  @moduledoc """
  LLM tool: plays the recent messages of the shared family answering machine
  (`Soundai.Messages`).

  `tool/0` builds the `ReqLLM.Tool` handed to the LLM. Without filters it
  reads out the last few messages within the retention window (press play on
  the tape); optional `from`/`to` narrow the playback when the user names
  someone ("dime el mensaje de Diego"). The callback returns a ready-to-speak
  Spanish script — the assistant repeats it verbatim, no rephrasing needed.

  Like a 90s contestador, nothing is consumed by listening: messages are
  never marked delivered or deleted, so they play again on every ask until
  they age out of the retention window (`Soundai.Messages` config:
  `:message_retention_days`, default 30; at most `:max_messages`, default 5,
  are read per call). Failures return `{:error, reason}` so `branched_llm`
  injects the error into the conversation context and the LLM can apologize
  in plain words.
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
        "Lee en voz alta los últimos mensajes del contestador familiar. Úsala cuando el " <>
          "usuario pregunte si tiene mensajes o pida escucharlos («¿Tengo algún mensaje?», " <>
          "«Dime el mensaje de Diego»). Sin filtros lee los últimos mensajes guardados. Pasa " <>
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
  Tool callback: returns `{:ok, script}` with the recent messages phrased for
  speech, or `{:error, reason}` when the database fails.
  """
  def get_messages(args) do
    opts = [from: opt(args, "from"), to: opt(args, "to")]

    with {:ok, messages} <- fetch_messages(opts) do
      case messages do
        [] -> {:ok, empty_text(opts)}
        messages -> {:ok, script(messages)}
      end
    end
  end

  # A database failure must surface as an error result, never a crash: the LLM
  # turns it into a spoken apology.
  defp fetch_messages(opts) do
    {:ok, Messages.pending_messages(opts)}
  rescue
    exception ->
      Logger.warning("Could not load messages for playback: #{Exception.message(exception)}")
      {:error, "could not access the messages"}
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

  defp script(messages) do
    intro =
      case length(messages) do
        1 -> "Este es tu último mensaje"
        count -> "Estos son tus últimos #{count} mensajes"
      end

    body = Enum.map_join(messages, " ", &entry/1)

    "#{intro}. #{body}"
  end

  # "de Diego: no te olvides de tomar agua hoy." / "de alguien: …"
  defp entry(message) do
    from = message.from_name || "alguien"
    "De #{from}: #{message.body}"
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
