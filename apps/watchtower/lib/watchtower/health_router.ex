defmodule Watchtower.HealthRouter do
  @moduledoc """
  Minimal Plug.Router exposing liveness (`/health`) and readiness (`/ready`)
  endpoints for container orchestration.
  """
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  # Liveness: if this responds at all, the VM is up.
  get "/health" do
    send_resp(conn, 200, "ok")
  end

  # Readiness: optionally require the node to have joined peers
  # before Kubernetes routes traffic to it.
  get "/ready" do
    min_peers = Application.get_env(:watchtower, :min_cluster_size, 0)
    connected = length(Node.list())

    if connected >= min_peers do
      send_resp(conn, 200, "ready (#{connected} peers)")
    else
      send_resp(conn, 503, "not ready (#{connected}/#{min_peers} peers)")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
