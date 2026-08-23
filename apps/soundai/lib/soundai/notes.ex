# Notes are intentionally public (there is no authentication in the app yet),
# so skip the missing-authorization heuristic.
# credo:disable-for-this-file OeditusCredo.Check.Security.MissingAuthorization
defmodule Soundai.Notes do
  @moduledoc """
  The user's single, freely editable note — one big text maintained through
  `/notes` and relayed verbatim to the LLM on every turn.

  Stored as one row in the `notes` table: saving replaces its content in
  place; the first save creates the row.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Soundai.Notes.Note
  alias Soundai.Repo

  @max_content_length 10_000

  @doc """
  The current note (`%Note{}`), or `nil` when it has never been saved.
  """
  def current_note do
    Repo.one(from(n in Note, order_by: [asc: n.id], limit: 1))
  end

  @doc """
  Changeset backing the edit form, prefilled with the current text.
  """
  def change_note do
    Note.changeset(current_note() || %Note{}, %{})
  end

  @doc """
  Replaces the whole note text: updates the existing row, or creates it on
  first save.

  ## Returns

    * `{:ok, note}` — the persisted note.
    * `{:error, %Ecto.Changeset{}}` — validation failure (empty or blank).
  """
  def save_note(attrs) do
    case current_note() do
      nil ->
        %Note{}
        |> Note.changeset(attrs)
        |> validate_length()
        |> Repo.insert()

      note ->
        note
        |> Note.changeset(attrs)
        |> validate_length()
        |> Repo.update()
    end
  end

  # Freeform notes: cap the stored size so a runaway paste cannot flood the
  # database.
  defp validate_length(changeset) do
    Changeset.validate_length(changeset, :content, max: @max_content_length, count: :bytes)
  end

  @doc """
  The current note's text, or `nil` when there is none.
  """
  def note_text do
    case current_note() do
      nil -> nil
      note -> note.content
    end
  end
end
