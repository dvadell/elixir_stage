defmodule Soundai.Repo.Migrations.ConsolidateNotesIntoSingleNote do
  use Ecto.Migration

  @moduledoc """
  The notes feature is one big, freely editable text: merge every existing row
  into the oldest one (contents concatenated newest-last so chronological
  order reads top-to-bottom) and drop the rest.
  """

  def up do
    # One-off data consolidation in plain SQL (not expressible with the
    # migration DSL), run once against PostgreSQL only.
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute """
    UPDATE notes AS target
    SET content = merged.content, updated_at = NOW()
    FROM (
      SELECT MIN(id) AS keep_id, string_agg(content, E'\\n' ORDER BY id DESC) AS content
      FROM notes
    ) AS merged
    WHERE target.id = merged.keep_id
    """

    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute "DELETE FROM notes WHERE id <> (SELECT MIN(id) FROM notes)"
  end

  # The dropped rows cannot be restored; rolling back leaves the single note.
  def down do
    :ok
  end
end
