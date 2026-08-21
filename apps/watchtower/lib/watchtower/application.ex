defmodule Watchtower.Application do
  @moduledoc """
  OTP application entrypoint: starts the DNS-based clustering member and
  the Bandit server that serves the health/readiness endpoints.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Registers this node with the cluster via DNS discovery; :ignore when unset.
      {DNSCluster, query: Application.get_env(:watchtower, :dns_cluster_query) || :ignore},
      {Bandit,
       plug: Watchtower.HealthRouter,
       scheme: :http,
       port: Application.get_env(:watchtower, :health_port, 4003)}
    ]

    # Supervise all children, restarting any single failing child in isolation.
    opts = [strategy: :one_for_one, name: Watchtower.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
