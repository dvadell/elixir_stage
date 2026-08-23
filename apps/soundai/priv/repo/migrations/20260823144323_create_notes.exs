defmodule Soundai.Repo.Migrations.CreateNotes do
  use Ecto.Migration

  def change do
    create table(:notes) do
      add :content, :text, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
