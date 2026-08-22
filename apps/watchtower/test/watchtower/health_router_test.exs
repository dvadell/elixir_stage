defmodule Watchtower.HealthRouterTest do
  use ExUnit.Case, async: true
  import Plug.Test

  defp call(path) do
    conn(:get, path, "GET") |> Watchtower.HealthRouter.call(Watchtower.HealthRouter.init([]))
  end

  test "liveness: /health responds 200 ok" do
    conn = call("/health")
    assert conn.status == 200
    assert conn.resp_body == "ok"
  end

  test "readiness: /ready is 200 when connected peers meet min_cluster_size" do
    try do
      Application.put_env(:watchtower, :min_cluster_size, 0)
      conn = call("/ready")
      assert conn.status == 200
      assert Regex.match?(~r/^ready \(\d+ peers\)$/, conn.resp_body)
    after
      Application.delete_env(:watchtower, :min_cluster_size)
    end
  end

  test "readiness: /ready is 503 when connected peers are below min_cluster_size" do
    try do
      # A min peer count that no single-node test VM can satisfy.
      Application.put_env(:watchtower, :min_cluster_size, 999)
      conn = call("/ready")
      assert conn.status == 503
      assert Regex.match?(~r/^not ready \(\d+\/999 peers\)$/, conn.resp_body)
    after
      Application.delete_env(:watchtower, :min_cluster_size)
    end
  end

  test "unknown paths respond 404" do
    conn = call("/definitely-not-a-route")
    assert conn.status == 404
    assert conn.resp_body == "not found"
  end
end
