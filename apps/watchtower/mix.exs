defmodule Watchtower.MixProject do
  use Mix.Project

  def project do
    [
      app: :watchtower,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Watchtower.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:dns_cluster, "~> 0.2"},
      {:plug, "~> 1.20"},
      {:bandit, "~> 1.12"}
    ]
  end
end
