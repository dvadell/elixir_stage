# Product Requirements Document: Standalone TTS Server (Node)

**Status:** Draft
**Purpose:** Define the product, architecture, API, deployment, and success
criteria for a small, self-contained **text-to-speech microservice** written in
Node.js. It is designed to run as **its own Kubernetes pod**, independent of the
Phoenix web applications, and is consumed **server-to-server** by `soundai`.

> This document lives in the top-level `tts_server/` directory of the `elixir_stage`
> monorepo, together with `TECHNICAL_NOTES.md` and `tickets/`. The whole folder is
> self-contained and can be moved into a new project/repository when the service is
> extracted into its own deployment.

## 1. Summary

A tiny HTTP service that turns text into speech:

```text
POST /v1/tts { "text": "Buenos días", "language": "spanish" }
  -> 200 audio/wav  (16-bit PCM, 16 kHz, mono)
```

It synthesizes Spanish speech using the **same model the browser already uses**
(`Xenova/mms-tts-spa`, a VITS model, ~36M params) via
`@huggingface/transformers`. It runs on **plain CPU** — no GPU required — and is
containerized for Kubernetes.

## 2. Background & problem

`soundai` is a voice-first assistant whose speech output is produced by the
browser (Web Speech API or a local in-browser VITS worker). In practice, on
mobile, browser TTS has two failure modes that break the product loop:

1. **It hangs**: after several turns the `onend` event stops firing (a known
   Web Speech API problem, often after `cancel()` races), leaving the app stuck
   on the "Speaking…" state with no timeout or recovery.
2. **It repeats the last word**: a documented Web Speech API quirk on some
   Android engines.

The app also has few debugging options on mobile.

A **server-side TTS** service solves both:

- it is a **reliable fallback** whose audio does not depend on the browser's
  speech stack; and
- it is a **diagnostic tool** — if the assistant still hangs with server-side
  TTS, the fault is elsewhere (server, LLM, network); if it stops hanging, the
  browser TTS was the culprit.

Because the platform is **Kubernetes**, TTS should be a **separate pod**: its own
image, resource limits, lifecycle, and rollout, with a clean network boundary
instead of a sidecar bolted onto the web app.

## 3. Goals

- Synthesize short Spanish replies with **sub-second to ~2 s latency** on plain
  CPU (the model runs ~4x faster than realtime in this class of runtime).
- Be **containerized and k8s-native**: health/readiness probes, graceful
  shutdown (drain in-flight synthesis), configuration through environment
  variables, no hardcoded hosts.
- Expose a **simple, stable API** that returns standard **WAV** audio directly
  decodable by any browser (`decodeAudioData`) with no extra client code.
- **Reuse existing knowledge and tooling**: `@huggingface/transformers` is
  already a dependency of `soundai`, Node is already installed on the dev
  machine, and the model was already benchmarked in Node (see
  `TECHNICAL_NOTES.md` §Benchmarks).
- Be **internal-only**: not exposed to the public internet; only the Phoenix
  apps talk to it.

## 4. Non-goals (MVP)

- **Streaming / chunked TTS** (begin speaking before synthesis finishes) — future.
- **Multiple voices / voice selection** — the model ships one voice; a `voice`
  parameter is reserved but unsupported in the MVP.
- **Utterance caching** (deduplicating identical texts) — future optimization.
- **Authentication / authorization** — the service is internal; a cluster
  network policy is the boundary. (If it is ever exposed, auth + rate limiting
  become required — see §Security.)
- **GPU acceleration** — CPU is sufficient for the target load.
- **Languages beyond Spanish** — the API carries a `language` field and the
  model map is data-driven, but only `spanish` is wired in the MVP.
- **Batching / request pipelining** — a single in-flight synthesis with a FIFO
  queue is enough (see `TECHNICAL_NOTES.md` §Concurrency).

## 5. System context

```text
┌─────────────┐      ┌──────────────────────────┐      ┌──────────────────────┐
│   Browser   │      │  soundai (Phoenix, pod)  │      │  TTS server (Node)   │
│  (voice UI) │ HTTP │  POST /api/tts           │ HTTP │  POST /v1/tts        │
│             ├─────►│  (proxy)                 ├─────►│  (synthesize)        │
│  audio/wav  │◄─────┤                          │◄─────┤  audio/wav           │
└─────────────┘      └──────────────────────────┘      └──────────┬───────────┘
                                                                  │ first start
                                                                  ▼
                                                       Hugging Face CDN (model)
```

- The **browser never calls the TTS pod directly**; it calls `soundai`'s
  `/api/tts`, which proxies to the pod. This keeps the TTS service internal and
  lets `soundai` remain the single entry point.
- The pod downloads the model from the Hugging Face CDN on **first start** and
  caches it (see `TECHNICAL_NOTES.md` §Model cache).

## 6. User stories

- **As a voice-assistant user**, I want to hear replies without the browser
  hanging or repeating the last word.
- **As a developer**, I want to select "server" TTS in `soundai`'s `/settings`
  and have a server-side fallback that is easy to debug from logs.
- **As an operator**, I want the TTS service to deploy, scale, probe, and
  recycle like any other pod, with sensible resource limits and no coupling to
  the web app.
- **As an operator**, I want the service to shut down cleanly (finish in-flight
  synthesis) when the pod is recycled.

## 7. API contract

### 7.1 `POST /v1/tts`

Synthesize speech from text.

Request:

```json
{ "text": "Hola, ¿cómo estás?", "language": "spanish" }
```

| Field      | Required | Rules                                                        |
|------------|----------|--------------------------------------------------------------|
| `text`     | yes      | non-empty trimmed string; ≤ `TTS_MAX_TEXT_LENGTH` (default 1000 chars) |
| `language` | no       | default `TTS_DEFAULT_LANGUAGE` (`spanish`); unknown → 422    |

Success — **200** `Content-Type: audio/wav`:

- Body: 16-bit PCM WAV, 16 kHz, mono (playable via `decodeAudioData`).
- Headers: `Content-Type: audio/wav`, `Content-Length`, `X-TTS-Model`,
  `X-TTS-Duration-Ms`.

Errors — always JSON `{"error": {"code": <code>, "message": <string>}}`:

| Status | Code           | Meaning                                    |
|--------|----------------|--------------------------------------------|
| 400    | `bad_request`  | invalid JSON body                          |
| 413    | `payload_too_large` | request body exceeds the size limit   |
| 422    | `missing_text` / `empty_text` / `text_too_long` / `unsupported_language` | validation failures |
| 503    | `not_ready`    | model still loading / warming              |
| 429    | `busy`         | queue full (saturated)                     |
| 500    | `synthesis_failed` | inference or encoding failure          |

### 7.2 `GET /healthz` (liveness)

`200 {"status":"ok"}` whenever the process is up. No model dependency.

### 7.3 `GET /readyz` (readiness)

`200 {"status":"ready"}` once the model is loaded and the queue accepts work;
`503 {"status":"starting"}` otherwise. K8s probes use this to gate traffic.

## 8. Functional requirements

- The model is loaded **once** at startup and reused for every request (no
  per-request downloads).
- Synthesis requests are **serialized** (one at a time) with a FIFO queue;
  queue length is bounded; saturated queues return `429` promptly.
- Every synthesis is bounded by a **timeout**; a hung inference is logged and
  never leaves a client hanging.
- `text` is untrusted input: validated, trimmed, length-capped. It is only ever
  passed to the model — never evaluated, logged in full by default, or echoed
  into HTML.
- The service **never** requires secrets; there is nothing to configure besides
  ports, limits, and the model id.

## 9. Non-functional requirements

- **Latency**: p50 synthesis ≤ 1.5 s and p95 ≤ 4 s for replies ≤ ~200 chars on
  the reference CPU pod; cold model load (first start) ≤ ~60 s.
- **Reliability**: a crashed inference returns `500` and the process stays up;
  OOM is handled by k8s restart policy; SIGTERM drains in-flight work.
- **Resources**: starts and serves within `limits.memory` (see
  `TECHNICAL_NOTES.md` §Deployment); numbers tuned after T0005 benchmark.
- **Observability**: structured logs with a request id, latency breakdown
  (queue wait + synthesis + encode), and a `/metrics` endpoint or equivalent.
- **Security**: binds to `0.0.0.0` **only** for in-cluster service traffic;
  public exposure is a non-goal. Rate limiting and auth are required if the
  service is ever exposed.

## 10. Acceptance criteria

- [ ] `POST /v1/tts` returns a playable WAV for Spanish text in a single round
      trip; `curl` works end-to-end.
- [ ] Validation (missing/blank/too-long text, unsupported language) returns the
      documented JSON errors.
- [ ] `/healthz` and `/readyz` behave as documented; k8s probes can rely on them.
- [ ] Model loads once and is reused; readiness flips only when the model is
      usable.
- [ ] Concurrent requests are serialized and queued; saturation returns `429`.
- [ ] SIGTERM drains in-flight synthesis before exit.
- [ ] Runs as a container; Dockerfile is small and reproducible (Node LTS slim).
- [ ] K8s manifests (Deployment + Service + probes + resources) deploy to a
      cluster; `soundai` reaches it via in-cluster DNS.
- [ ] Latency and memory are measured and documented (T0005).
- [ ] `soundai` integration contract (§7) is documented and stable.

## 11. Roadmap

| Ticket | Deliverable                                            |
|--------|--------------------------------------------------------|
| T0001  | Scaffold: HTTP server, config, `/healthz` + `/readyz`, Dockerfile |
| T0002  | Synthesis: model load, WAV encoding, `POST /v1/tts`    |
| T0003  | Robust serving: serialized queue, timeouts, graceful shutdown, model cache |
| T0004  | Kubernetes deployment: manifests, probes, resources, model-cache volume |
| T0005  | Observability + benchmark: logs, latency metrics, load test, memory |

## 12. Success metrics

- Soundai operators can point the voice assistant at "server" TTS from
  `/settings` and confirm the hang/repeat-last-word symptom disappears.
- `p95` synthesis latency stays within budget on the reference pod; OOM restarts
  are effectively zero.
- The pod deploys and upgrades via normal k8s rollout; zero manual steps.

## 13. Open questions

1. Is a single pod with one synthesis worker enough, or will the worker_threads
   pool (T0003 future) be needed for expected concurrency?
2. Should the model be baked into the image (faster start, larger image) instead
   of downloaded + cached at first start?
3. Do we eventually want a non-Spanish model (the API already carries
   `language`)? Which languages?
4. When the LLM lands in `soundai`, should the TTS pod also offer streaming?