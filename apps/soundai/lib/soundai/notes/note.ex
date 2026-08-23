defmodule Soundai.Notes.Note do
  @moduledoc """
  A freeform text note persisted in the database.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "notes" do
    field(:content, :string)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(note, attrs) do
    note
    |> cast(attrs, [:content])
    |> validate_required([:content])
    |> update_change(:content, &String.trim/1)
  end
end
