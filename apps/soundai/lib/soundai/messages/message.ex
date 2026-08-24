defmodule Soundai.Messages.Message do
  @moduledoc """
  A family message ("recado") persisted in the database — one entry on the
  answering-machine tape: a body plus optional sender and recipient names,
  both free text. `delivered_at` is stamped when the message is played back.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @max_body_bytes 500
  @max_name_bytes 100

  schema "messages" do
    field(:body, :string)
    field(:from_name, :string)
    field(:to_name, :string)
    field(:delivered_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: integer() | nil,
          body: String.t() | nil,
          from_name: String.t() | nil,
          to_name: String.t() | nil,
          delivered_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:body, :from_name, :to_name])
    |> validate_required([:body])
    |> update_change(:body, &String.trim/1)
    |> update_change(:from_name, &trim_to_nil/1)
    |> update_change(:to_name, &trim_to_nil/1)
    |> validate_length(:body, max: @max_body_bytes, count: :bytes)
    |> validate_length(:from_name, max: @max_name_bytes, count: :bytes)
    |> validate_length(:to_name, max: @max_name_bytes, count: :bytes)
  end

  # Blank names are stored as NULL so the playback phrasing can fall back to
  # "alguien" without special-casing empty strings.
  defp trim_to_nil(name) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_to_nil(_other), do: nil
end
