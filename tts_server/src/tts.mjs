// TTS model lifecycle and synthesis (T0002).
//
// Export:
//   class TTS
//   class TTSError extends Error   (kind: "inference" | "loading")
//
//   new TTS(cfg, log)
//     cfg: loadConfig() result
//     log: (level, msg, fields) structured logger (src/log.mjs)
//
//   await tts.start()
//     Configures env (TECHNICAL_NOTES.md §2) and loads the pipeline for
//     cfg.model (CPU/WASM, dtype from cfg) ONCE. A cold start (no cache)
//     downloads the model and logs progress milestones so it is observable; a
//     cache-hit start loads from disk and logs "model loaded from cache"
//     instead (T0003c). Sets the readiness flag when the model is usable; on
//     failure the process stays up (liveness is independent) and /readyz keeps
//     gating traffic.
//
//   tts.isReady() -> boolean
//     Readiness for /readyz; false until the model finishes loading.
//
//   tts.supportedLanguages() -> string[]
//     Keys of the language -> model map, for request validation.
//
//   await tts.synthesize(text, language, requestId = null) -> { audio: Float32Array, samplingRate: number }
//     One synthesis on the shared pipeline. Throws TTSError("inference") on
//     failure, TTSError("loading") if the model is not ready. requestId is
//     only used for the failure log line.
//
// Invariants (TECHNICAL_NOTES.md §3, §9):
//   - One synthesis in flight per pipeline; callers MUST go through the queue.
//   - No per-request model downloads; the model loads once at startup.
//   - Text is untrusted: it is only ever passed to the model, never logged in
//     full by default (log length, not content).

import { existsSync } from "node:fs";
import { join } from "node:path";
import { env, pipeline } from "@huggingface/transformers";

// Language -> HF model id (data-driven; PRD §4: MVP ships Spanish only).
const LANGUAGES = {
  spanish: "Xenova/mms-tts-spa",
};

export class TTSError extends Error {
  constructor(kind, message, cause) {
    super(message, cause ? { cause } : undefined);
    this.name = "TTSError";
    this.kind = kind; // "inference" | "loading"
  }
}

export class TTS {
  #cfg;
  #log;
  #ready = false;
  #pipeline = null; // loaded pipeline instance, reused for every request
  #modelId;
  #cacheDir = null; // effective cache dir (configured or transformers default)
  #preCached = false; // the model was already in the cache before this start
  #progressPct = {}; // per-file throttled download % (events are transient)

  constructor(cfg, log) {
    this.#cfg = cfg;
    this.#log = log;
    this.#modelId = cfg.model;

    // Env exactly as in TECHNICAL_NOTES.md §2 (env is a module-global from
    // @huggingface/transformers; these flags must be set before the first
    // pipeline call).
    if (cfg.cacheDir) env.cacheDir = cfg.cacheDir;
    env.allowLocalModels = false;
    env.useBrowserCache = false;
    env.useWasmCache = false;
    env.logLevel = "warning";

    // transformers.js replays its per-file progress events on cache hits too,
    // so the events alone cannot tell a download from a cache read (T0003c).
    // Check the cache up front instead: a populated model dir means this start
    // will read from disk, so the "download" milestones below are suppressed.
    this.#cacheDir = cfg.cacheDir ?? env.cacheDir;
    this.#preCached =
      typeof this.#cacheDir === "string" &&
      this.#cacheDir.length > 0 &&
      existsSync(join(this.#cacheDir, this.#modelId));
  }

  // Data-driven language map; request languages are validated against it.
  #modelFor(language) {
    return language ? LANGUAGES[language] ?? null : null;
  }

  supportedLanguages() {
    return Object.keys(LANGUAGES);
  }

  get modelId() {
    return this.#modelId;
  }

  isReady() {
    return this.#ready;
  }

  async start() {
    const startedAt = Date.now();
    this.#log("info", "loading model", { model: this.#modelId, dtype: this.#cfg.dtype });
    if (this.#preCached) {
      this.#log("info", "model loaded from cache", {
        model: this.#modelId,
        cacheDir: this.#cacheDir,
      });
    }
    try {
      // The loaded pipeline is reused for every request (no per-request
      // downloads). "cpu" is the valid backend in the Node build (v4.2.0
      // ships onnxruntime-node natively; "wasm" is only accepted by the
      // browser build).
      this.#pipeline = await pipeline("text-to-speech", this.#modelId, {
        device: "cpu",
        dtype: this.#cfg.dtype,
        progress_callback: (data) => this.#onProgress(data),
      });
      this.#ready = true;
      this.#log("info", "[tts] model ready", {
        model: this.#modelId,
        dtype: this.#cfg.dtype,
        loadMs: Date.now() - startedAt,
      });
    } catch (err) {
      this.#log("error", "model load failed", {
        model: this.#modelId,
        loadMs: Date.now() - startedAt,
        msg: err?.message,
      });
      throw new TTSError("loading", `model load failed: ${err?.message}`, err);
    }
  }

  // First start downloads the model (~38 MB q8); log each file's start,
  // completion, and 25%-step progress so a cold pod is observable. On a
  // cache-hit start these events are replayed for the disk read, so they are
  // suppressed entirely (the "model loaded from cache" line covers that case).
  #onProgress(data) {
    if (this.#preCached) return;
    if (!data || !data.status) return;
    switch (data.status) {
      case "initiate":
        this.#progressPct[data.file] = 0;
        this.#log("info", "model download started", {
          model: this.#modelId,
          file: data.file,
          totalBytes: data.total ?? null,
        });
        break;
      case "done":
        delete this.#progressPct[data.file];
        this.#log("info", "model file cached", { model: this.#modelId, file: data.file });
        break;
      case "progress": {
        // Throttle to 25% steps per file; transformers fires per chunk.
        if (data.total > 0 && data.progress >= (this.#progressPct[data.file] ?? 0)) {
          const pct = Math.floor(data.progress);
          this.#progressPct[data.file] = Math.ceil(pct / 25) * 25;
          this.#log("info", "model download", {
            model: this.#modelId,
            file: data.file,
            pct: Math.min(99, pct),
          });
        }
        break;
      }
      default:
        break;
    }
  }

  async synthesize(text, language, requestId = null) {
    if (!this.#ready || !this.#pipeline) {
      throw new TTSError("loading", "model is not ready");
    }
    // MVP: only `spanish` is wired, so the request language must map to the
    // model that was loaded at startup (the single shared pipeline).
    const modelId = this.#modelFor(language);
    if (modelId && modelId !== this.#modelId) {
      throw new TTSError("loading", `no pipeline loaded for language "${language}"`);
    }
    try {
      const out = await this.#pipeline(text);
      if (!out?.audio || typeof out.sampling_rate !== "number") {
        throw new TTSError("inference", "model returned no audio output");
      }
      return { audio: out.audio, samplingRate: out.sampling_rate };
    } catch (err) {
      if (err instanceof TTSError) throw err;
      // Never log the full untrusted text; length only.
      this.#log("error", "synthesis failed", {
        model: this.#modelId,
        requestId,
        textLen: text?.length ?? 0,
        language: language ?? null,
        msg: err?.message,
      });
      throw new TTSError("inference", `synthesis failed: ${err?.message}`, err);
    }
  }
}