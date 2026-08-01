defmodule Soundpanel.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SoundpanelWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:soundpanel, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Soundpanel.PubSub},
      # Start a worker by calling: Soundpanel.Worker.start_link(arg)
      # {Soundpanel.Worker, arg},
      # Start to serve requests, typically the last entry
      SoundpanelWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Soundpanel.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SoundpanelWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
