# Notes are intentionally public (there is no authentication in the app yet),
# so skip the missing-authorization heuristic.
# credo:disable-for-this-file OeditusCredo.Check.Security.MissingAuthorization
defmodule Soundai.Notes do
  @moduledoc """
  Persistence for freeform text notes.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Soundai.Notes.Note
  alias Soundai.Repo

  @max_content_length 10_000

  defdelegate changeset(note, attrs), to: Note

  @doc """
  Creates a note from freeform text.

  ## Returns

    * `{:ok, note}` — the persisted note.
    * `{:error, %Ecto.Changeset{}}` — validation failure (empty or blank).
  """
  def create_note(attrs) do
    %Note{}
    |> Note.changeset(attrs)
    |> validate_length()
    |> Repo.insert()
  end

  # Freeform notes: cap the stored size so a runaway paste cannot flood the
  # database.
  defp validate_length(changeset) do
    Changeset.validate_length(changeset, :content, max: @max_content_length, count: :bytes)
  end

  @doc """
  Lists all notes, newest first.
  """
  def list_notes do
    Repo.all(from(n in Note, order_by: [desc: n.inserted_at, desc: n.id]))
  end
end
