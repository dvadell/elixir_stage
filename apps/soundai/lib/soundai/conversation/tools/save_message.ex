defmodule Soundai.Conversation.Tools.SaveMessage do
  @max_name_bytes 100

  @moduledoc """
  LLM tool: saves a family message on the shared answering machine
  (`Soundai.Messages`).

  `tool/0` builds the `ReqLLM.Tool` handed to the LLM. Given a recipient, a
  message body and an optional sender (extracted from speech like "soy
  Diego"), the callback persists the row and returns a short Spanish,
  voice-friendly confirmation ("Mensaje guardado para Diego.") that the
  assistant can speak as-is — the LLM is only a relay.

  Failures return `{:error, reason}` so `branched_llm` injects the error into
  the conversation context and the LLM can tell the user in plain words.
  Database outages included: the callback never raises.
  """

  require Logger

  alias Soundai.Messages

  @doc """
  Builds the `save_message` tool for the LLM.
  """
  @spec tool() :: ReqLLM.Tool.t()
  def tool do
    ReqLLM.Tool.new!(
      name: "save_message",
      description:
        "Guarda un mensaje para otra persona en el contestador familiar. Úsala cuando el " <>
          "usuario diga algo como «Mensaje para X: …» o «Déjale un mensaje a X». Pasa en " <>
          "'to' el nombre de la persona destinataria tal como el usuario lo dijo y en 'body' " <>
          "el texto exacto del mensaje. Si el usuario dijo su nombre («Soy Diego», «te dice " <>
          "María…») pásalo en 'from'; si no lo sabe, omítelo.",
      parameter_schema: %{
        type: "object",
        properties: %{
          to: %{
            type: "string",
            description: "Nombre de la persona destinataria del mensaje"
          },
          body: %{
            type: "string",
            description: "Texto del mensaje, tal como el usuario lo dictó"
          },
          from: %{
            type: "string",
            description:
              "Nombre de quien deja el mensaje; omítelo si el usuario no dijo su nombre"
          }
        },
        required: ["to", "body"]
      },
      callback: &save_message/1
    )
  end

  @doc """
  Tool callback: returns `{:ok, confirmation}` after persisting the message,
  or `{:error, reason}` when arguments are missing/oversized or the database
  fails.
  """
  def save_message(args) do
    with :ok <- required(args, "to"),
         :ok <- required(args, "body"),
         {:ok, attrs} <- build_attrs(args),
         {:ok, message} <- persist(attrs) do
      {:ok, confirmation(message.to_name)}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset_error(changeset)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Repo.insert raises on database outages (DBConnection.ConnectionError and
  # friends); like GetMessages, a failure must surface as an error result so
  # branched_llm turns it into a spoken apology instead of a crash.
  defp persist(attrs) do
    Messages.save_message(attrs)
  rescue
    exception ->
      Logger.warning("Could not save a message: #{Exception.message(exception)}")
      {:error, "could not save the message"}
  end

  defp build_attrs(%{"to" => to, "body" => body} = args) do
    with :ok <- within_limit("to", to, @max_name_bytes),
         :ok <- within_limit("from", args["from"], @max_name_bytes) do
      {:ok,
       %{
         "body" => body,
         "to_name" => to,
         "from_name" => Map.get(args, "from")
       }}
    end
  end

  defp within_limit(_key, nil, _limit), do: :ok

  defp within_limit(key, value, limit) when is_binary(value) do
    if byte_size(String.trim(value)) > limit do
      {:error, "#{key} is too long (over #{limit} bytes)"}
    else
      :ok
    end
  end

  defp within_limit(_key, _other, _limit), do: {:error, "invalid arguments"}

  defp required(args, key) do
    case args[key] do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, "missing #{key}"}, else: :ok

      _other ->
        {:error, "missing #{key}"}
    end
  end

  # Validation errors are non-empty here in practice, but a constraint failure
  # would return an error-less changeset — never let the callback raise. Error
  # templates ("%{count}") are interpolated so the LLM never sees placeholders.
  defp changeset_error(changeset) do
    case Enum.at(changeset.errors, 0) do
      {field, {message, opts}} ->
        "#{field}: #{interpolate(message, opts)}"

      _ ->
        "could not save the message"
    end
  end

  defp interpolate(message, opts) do
    Regex.replace(~r"%\{(\w+)\}", message, fn _match, key ->
      case Keyword.fetch(opts, String.to_existing_atom(key)) do
        {:ok, value} -> to_string(value)
        :error -> "%{#{key}}"
      end
    end)
  rescue
    _error in [ArgumentError, KeyError] ->
      message
  end

  defp confirmation(nil), do: "Mensaje guardado."
  defp confirmation(to_name), do: "Mensaje guardado para #{to_name}."
end
