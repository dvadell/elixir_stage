defmodule Soundai.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SoundaiWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:soundai, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Soundai.PubSub},
      Soundai.Conversation.Store,
      # Start a worker by calling: Soundai.Worker.start_link(arg)
      # {Soundai.Worker, arg},
      # Start to serve requests, typically the last entry
      SoundaiWeb.Endpoint
    ]

    # In-process TTS (Ortex/ONNX) — only started when a model is configured.
    children = children ++ tts_server_children()

    opts = [strategy: :one_for_one, name: Soundai.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp tts_server_children do
    if Soundai.TTS.enabled?() do
      [{Soundai.TTS.OrtexServer, model_path: Soundai.TTS.model_path()}]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SoundaiWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
