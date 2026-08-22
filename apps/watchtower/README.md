# Watchtower

A small, self-contained Elixir app that serves Kubernetes **liveness** and **readiness** probes for the application, and manages **node clustering** via DNS discovery.

Watchtower runs as its own OTP application alongside the main application. It starts a dedicated Bandit HTTP server for probe traffic and a `DNSCluster` member for peer discovery — keeping health checking and cluster management out of the main application's supervision tree.

## Architecture

```
                 ┌──────────────────────────────┐
                 │      Watchtower.Supervisor   │
                 │         (one_for_one)        │
                 └──────────────────────────────┘
                  │                        │
                  ▼                        ▼
         ┌────────────────┐       ┌───────────────────┐
         │     Bandit     │       │    DNSCluster     │
         │ (health server)│       │ (DNS-based node   │
         │   :4003        │       │  discovery &      │
         │                │       │  registration)    │
         └───────┬────────┘       └───────────────────┘
                 │
        ┌────────┴────────┐
        ▼                 ▼
   GET /health      GET /ready
   liveness         readiness
   probe            probe
```

## Endpoints

| Endpoint    | Method | Purpose                                              | Response |
| ----------- | ------ | ---------------------------------------------------- | -------- |
| `/health`   | `GET`  | **Liveness** — the VM and HTTP server are up.        | `200 ok` |
| `/ready`    | `GET`  | **Readiness** — the node is connected to enough peers. | `200 ready (N peers)` or `503 not ready (N/M peers)` |

- **Liveness** (`/health`) is intentionally trivial: if it responds, the process is alive. Kubernetes restarts the container only when this fails, so it must never depend on external state.
- **Readiness** (`/ready`) reports the number of connected peers from `Node.list()`. The node is considered ready once it has joined at least `min_cluster_size` peers. Until then, Kubernetes holds traffic to it.

## Configuration

All settings live under the `:watchtower` application environment key.

| Key               | Default | Description |
| ----------------- | ------- | ----------- |
| `health_port`     | `4003`  | Port for the health/readiness HTTP server. |
| `min_cluster_size`| `0`     | Minimum number of connected peers required for `/ready` to return `200`. `0` means ready as soon as the VM starts (standalone mode). |
| `dns_cluster_query`| `:ignore` | DNS query used by `DNSCluster` to discover and register peer nodes. |

Example (`config/config.exs`):

```elixir
config :watchtower,
  health_port: 4003,
  # Bump to 1+ if you want readiness to depend on joined peers
  min_cluster_size: 0
```

The `DNS_CLUSTER_QUERY` environment variable is read at runtime (`config/runtime.exs`):

```elixir
config :watchtower, dns_cluster_query: System.get_env("DNS_CLUSTER_QUERY")
```

When unset, `DNSCluster` is started with `:ignore` — clustering is disabled and the node runs standalone, with readiness determined by `min_cluster_size` alone (set it to `0` for true standalone readiness).

## Running in Kubernetes

Point the probes at the health server port:

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 4003
  initialDelaySeconds: 5
  periodSeconds: 10

readinessProbe:
  httpGet:
    path: /ready
    port: 4003
  initialDelaySeconds: 5
  periodSeconds: 10
```

`DNS_CLUSTER_QUERY` should resolve to the service's cluster DNS name so each pod discovers its peers, e.g. `my-service.default.svc.cluster.local`.

## How It Works

`Watchtower.Application` starts two children under a `:one_for_one` supervisor:

1. **`DNSCluster`** — registers this node with the cluster via DNS service discovery. Peers found through the DNS query are connected automatically as Erlang/OTP nodes.
2. **`Bandit`** — an HTTP server serving `Watchtower.HealthRouter`, a minimal `Plug.Router`.

Failing children are restarted in isolation, so a probe server outage never takes down clustering (or vice versa).

## Dependencies

| Package      | Purpose                          |
| ------------ | -------------------------------- |
| [`bandit`](https://hex.pm/packages/bandit) | High-performance BEAM HTTP server for the probe endpoints. |
| [`dns_cluster`](https://hex.pm/packages/dns_cluster) | DNS-based discovery and registration of cluster peers. |
| [`plug`](https://hex.pm/packages/plug) | Web middleware framework for the router. |
| [`req`](https://hex.pm/packages/req) | HTTP client (available for callers). |

## Development

```bash
# Compile
mix compile --app watchtower

# Run tests
mix test --app watchtower
```

Tests use `health_port: 4004` to avoid colliding with a locally running dev server.