// TTS model lifecycle and synthesis (contents land in T0002).
//
// Export:
//   class TTS
//
//   new TTS(cfg, log)
//     cfg: loadConfig() result
//     log: (level, msg, fields) structured logger (src/log.mjs)
//
//   await tts.start()
//     Loads the pipeline ONCE from cfg.model (CPU/WASM). Before T0002 this
//     is an async no-op kept as the T0002 load hook.
//
//   tts.isReady() -> boolean
//     Readiness for /readyz. Constant false in T0001; T0002 flips it when the
//     model finishes loading.
//
//   await tts.synthesize(text, language) -> { audio: Float32Array, samplingRate: number }
//     Returns raw model output. Throws on inference failure. Stub in T0001;
//     the HTTP layer answers 503 not_ready while !isReady().
//
// Invariants (TECHNICAL_NOTES.md §3, §9):
//   - One synthesis in flight per pipeline; callers MUST go through the queue.
//   - No per-request model downloads; the model loads once at startup.
import { env } from "@huggingface/transformers";

export class TTS {
  #cfg;
  #log;
  #ready = false;
  #pipeline = null; // T0002: loaded pipeline instance, reused for every request

  constructor(cfg, log) {
    this.#cfg = cfg;
    this.#log = log;
    if (cfg.cacheDir) env.cacheDir = cfg.cacheDir;
    env.allowLocalModels = false;
    env.useBrowserCache = false;
    env.useWasmCache = false;
    env.logLevel = "warning";
  }

  async start() {
    // T0002: load pipeline("text-to-speech", cfg.model, { device: "wasm" })
    // here, set #ready = true when done, and never make liveness depend on
    // this call (TECHNICAL_NOTES.md §9).
  }

  isReady() {
    return this.#ready;
  }

  async synthesize(_text, _language) {
    throw new Error("tts.synthesize not implemented yet (T0002)");
  }
}