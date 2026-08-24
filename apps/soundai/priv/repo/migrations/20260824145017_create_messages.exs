defmodule Soundai.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages) do
      add :body, :text, null: false
      add :from_name, :string
      add :to_name, :string
      add :delivered_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end
  end
end
