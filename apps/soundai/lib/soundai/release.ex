defmodule Soundai.Release do
  @moduledoc """
  Release tasks invoked by rel/overlays/bin/migrate. Releases ship without
  Mix, so `mix ecto.migrate` cannot run inside the container; this module is
  the entry point that applies pending migrations instead.
  """

  @app :soundai

  def migrate do
    load_app()

    for repo <- repos() do
      path = Ecto.Migrator.migrations_path(repo)
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, path, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
