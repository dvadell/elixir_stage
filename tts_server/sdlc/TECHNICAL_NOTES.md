# TTS Server (Node) — Technical Notes

Standalone text-to-speech microservice. Node.js + `@huggingface/transformers`,
synthesizing Spanish with `Xenova/mms-tts-spa` (VITS, ~36M params) on plain CPU,
returning WAV audio. Designed to run as its **own Kubernetes pod**, consumed
server-to-server by `soundai`.

This folder (`tts_server/` at the repo root of `elixir_stage`) is the
**seed of a new project**. It is self-contained so the whole folder can move
to its own repository. Intended layout:

```text
tts_server/
├── package.json          # only @huggingface/transformers
├── Dockerfile
├── src/
│   ├── server.mjs        # HTTP entry point (node:http, no framework)
│   ├── tts.mjs           # model lifecycle + synthesize
│   ├── queue.mjs         # serialized FIFO queue + timeouts
│   └── wav.mjs           # Float32Array -> WAV encoder
├── deploy/
│   ├── deployment.yaml   # Deployment + probes + resources + volume
│   └── service.yaml      # internal ClusterIP Service
└── test/
    └── api.test.mjs      # node:test integration tests
```

---

## 1. Why Node (and not Python)

- `@huggingface/transformers` is **already a dependency** of `soundai`
  (`apps/soundai/assets/package.json`, `^4.2.0`), Node v22 is installed on the
  dev machine, and `apps/soundai/sdlc/tickets/T0008_test_tts.mjs` already proved
  this exact model runs in Node here.
- **Same model + library as the browser**: `soundai`'s browser TTS uses
  `Xenova/mms-tts-spa` via transformers.js too, so server output
  (`Float32Array` @16 kHz) is apples-to-apples with the browser path — exactly
  what the diagnostic feature needs.
- Python would mean adding a **new ML toolchain**: `transformers` + PyTorch is
  a ~1–2 GB installed runtime, and the lighter ONNX Runtime route requires
  hand-writing the VITS forward pass. Node reuses everything already present.

## 2. Runtime & model

- **Transformers.js** in Node uses **onnxruntime-web (WASM)** by default —
  CPU-only, no GPU. `apps/soundai/assets/package.json` pins
  `onnxruntime-web` to `1.27.0` via overrides; keep the same override.
- Model: `Xenova/mms-tts-spa` (`facebook/mms-tts-spa` exported to ONNX).
  - Pipeline: `pipeline("text-to-speech", modelId, {device: "wasm", dtype})`.
  - Default dtype is `q8` (quantized, ~38 MB download) — the TTS VITS decoder is
    far less quantization-sensitive than Whisper's encoder, so `q8` is fine.
    `fp32` (~114 MB) is available via `{dtype: "fp32"}` if quality/artifacts are
    a concern.
  - Output: `{ audio: Float32Array, sampling_rate: 16000 }`.
- Env flags to set (mirror `T0008_test_tts.mjs`):
  `env.allowLocalModels = false; env.useBrowserCache = false;
  env.useWasmCache = false; env.logLevel = "warning";`
- **Model cache**: Node caches downloads under
  `env.cacheDir` (default:
  `node_modules/@huggingface/transformers/dist/.cache/`). Set `env.cacheDir`
  from `TTS_CACHE_DIR` so the k8s pod can mount a persistent volume (see
  §6). Each pod otherwise re-downloads on first start.

## 3. Concurrency model

onnxruntime-web is **single-threaded per session**: two concurrent `synthesize`
calls on the same pipeline trample the session. The MVP therefore uses a
**serialized FIFO queue**:

```text
request -> queue (bounded) -> synthesize (one at a time) -> encode -> respond
```

- One synthesis in flight; the rest wait.
- Bounded queue (e.g. `TTS_MAX_QUEUE` = 8); when full → **429** immediately
  (don't make clients wait behind a runaway backlog).
- Per-request timeout (e.g. `TTS_SYNTH_TIMEOUT_MS` = 30 s): a hung inference is
  logged, the queue moves on, the client gets 500. **Never leave a client
  hanging.**
- **Future**: a `worker_threads` pool (N = `hardwareConcurrency`) lifts the
  concurrency ceiling; each worker loads its own copy of the model, so memory
  grows ~linearly with N. Only needed if expected concurrency exceeds 1.

## 4. Audio encoding (WAV)

Transformers.js returns `Float32Array` samples @ 16 kHz. Encode to a standard
44-byte-header WAV (16-bit PCM little-endian, mono) so any browser can decode it
with `AudioContext.decodeAudioData` with no client-side parsing:

```text
RIFF header | fmt chunk (PCM, 1 ch, 16000 Hz, 16 bit) | data chunk (PCM16)
```

No external dependency needed; ~30 lines. Return `Content-Type: audio/wav`.

## 5. HTTP layer & config

- **Plain `node:http`** — one POST route + two GET health routes; a framework
  dep buys nothing here and bloats the image.
- Graceful shutdown: on `SIGTERM`/`SIGINT`, stop accepting, drain the queue
  (finish in-flight + queued synthesis), then exit 0. K8s `terminationGracePeriodSeconds`
  must be ≥ the drain budget.
- Configuration via env (all with defaults):

| Env var                  | Default              | Meaning                                |
|--------------------------|----------------------|----------------------------------------|
| `HOST`                   | `0.0.0.0`            | bind address (in-cluster service)      |
| `PORT`                   | `8080`               | HTTP port                              |
| `TTS_MODEL`              | `Xenova/mms-tts-spa` | HF model id                            |
| `TTS_DTYPE`              | `q8`                 | model precision (`q8` \| `fp32`)       |
| `TTS_DEFAULT_LANGUAGE`   | `spanish`            | language when request omits it         |
| `TTS_MAX_TEXT_LENGTH`    | `1000`               | max chars per request                  |
| `TTS_MAX_QUEUE`          | `8`                  | queue bound before 429                 |
| `TTS_SYNTH_TIMEOUT_MS`   | `30000`              | per-synthesis timeout                  |
| `TTS_CACHE_DIR`          | transformers default | model cache dir (mounted volume in k8s)|

- Logs: structured `{level, msg, requestId, queueWaitMs, synthMs, encodeMs,
  bytes, model}` — this is `soundai`'s mobile debugging instrument.

## 6. Container & Kubernetes

**Dockerfile** (multi-stage, pinned `node:22.20.0-slim` — pin matches the
installed Node v22.20.0 for reproducible builds):

```dockerfile
ARG NODE_VERSION=22.20.0

FROM node:${NODE_VERSION}-slim AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci

FROM node:${NODE_VERSION}-slim
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY src ./src
ENV NODE_ENV=production
USER node
EXPOSE 8080
CMD ["node", "src/server.mjs"]
```

**Deployment** (`deploy/deployment.yaml`, sketch):

- `replicas: 1` (synthesis is serialized; scale later with the worker pool).
- `strategy: RollingUpdate` with `maxUnavailable: 0` (only 1 replica).
- Probes:
  - `livenessProbe: httpGet /healthz` (port 8080) — process up.
  - `readinessProbe: httpGet /readyz` — model ready + queue accepting; period ~5s,
    `initialDelaySeconds` enough for model load (~30–60 s) — else the probe
    starts failing immediately after startup. Set `failureThreshold` generously
    so a cold start (model download) doesn't crash-loop.
- Resources (start point, **tune after T0005**): `requests: {cpu: 250m,
  memory: 384Mi}`, `limits: {cpu: 1, memory: 768Mi}`. The q8 model +
  onnxruntime-web WASM typically fit comfortably under 768 Mi.
- Model cache: either bake the model into the image (faster start, bigger image)
  or mount a `PersistentVolumeClaim` at `TTS_CACHE_DIR`. EmptyDir re-downloads
  on every pod start (~8 s load + download) — acceptable during development.
- **Service** (`deploy/service.yaml`): `ClusterIP` only, port 8080 → targetPort
  8080. **Not** exposed externally; cluster network policy is the boundary.

In-cluster DNS for consumers: `http://tts-server.<namespace>.svc.cluster.local:8080`
(or the namespace-relative `http://tts-server:8080`).

## 7. soundai integration (consumer contract)

`soundai` (Elixir/Phoenix) talks to this pod server-to-server:

1. `soundai` gains `Soundai.TTS` (provider abstraction) + `POST /api/tts`
   proxy controller, calling the pod with **Req** (the project's required HTTP
   client). Base URL from `SOUNDAI_TTS_URL` (defaults to the in-cluster DNS).
2. The browser's `server` TTS engine (`tts_engine.js`) calls `soundai`'s
   `/api/tts`, gets `audio/wav`, and plays it via `decodeAudioData` → Web Audio
   (bypassing `speechSynthesis` and the local VITS worker entirely).
3. `/settings` gains a "server" option in `@tts_models` (experimental).

The pod's API is the contract; see `PRD.md` §7. A failing/off pod is surfaced
by `soundai` as a quiet note + native-engine fallback (no error state), matching
the app's existing graceful-failure rules.

## 8. Benchmarks (from T0008, Node 22, WASM/CPU, single cold run)

Reference for expectations — **not** a promise on the pod:

| Metric                                  | Value    |
|-----------------------------------------|----------|
| Model download size (q8)                | ~38 MB   |
| Cold load (download + compile)          | ~8.3 s   |
| Primed synthesis, ~7 s Spanish text     | ~1.7 s   |
| Synthesis ratio (audio/wall-clock)      | ~4.0x    |
| Sampling rate                           | 16 kHz   |

Short replies (~2–4 s audio) should synthesize in ~0.5–1 s on the pod's CPU.
T0005 re-measures on the actual pod and records memory footprint.

## 9. Gotchas & conventions

- **Stable pin `onnxruntime-web`**: keep the `overrides` pin (1.27.0) from
  `soundai`'s assets so WASM behavior stays reproducible.
- **Serialized synthesis**: never call `synthesize` concurrently on one
  pipeline; always go through the queue.
- **Readiness ≠ liveness**: `/readyz` gates traffic on model load; do not make
  liveness depend on the model or a slow download will crash-loop the pod.
- **Never hang a client**: every request path ends in a response (200/4xx/5xx)
  or a timeout.
- **No secrets**: the service needs none; don't add any.
- **Text is untrusted**: cap length, don't log full text by default (log length
  and a request id).
- **Relocation**: this folder is the project seed. When moved to its own repo,
  the `deploy/` manifests and `src/` code travel with it; only the
  `soundai`-side proxy ticket stays behind.