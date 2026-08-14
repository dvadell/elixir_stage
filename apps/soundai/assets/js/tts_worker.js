// TTS synthesis worker.
//
// Runs entirely in a Web Worker so that model loading and inference do not
// block the browser's main UI thread. See `assets/js/voice_assistant.js` for
// the main-thread controller that talks to this worker.
//
// Device selection (WebGPU preferred, WASM/CPU fallback) is decided on the
// main thread and passed in the `init` message. If WebGPU initialization
// fails at runtime we automatically retry with WASM and notify the main
// thread via a `fallback` message.
import { LogLevel, env, pipeline } from "@huggingface/transformers";

env.allowLocalModels = false;
// Cache the model weights and the WASM runtime binary in the browser Cache
// Storage so subsequent sessions do not re-download them.
env.useBrowserCache = true;
env.useWasmCache = true;
env.logLevel = LogLevel.WARNING;

let synthesizerPromise = null;
let loadedDevice = null;
let loadedConfig = null;

// Generation counter to discard stale synthesis results when cancel() is called.
let currentGeneration = 0;

function log(...args) {
  console.log("[soundai:tts-worker]", ...args);
}

function post(message) {
  self.postMessage(message);
}

async function loadPipeline(options) {
  const deviceName = options?.device || "wasm";
  const modelId = options?.model;
  const dtype = options?.dtype;

  if (!modelId) {
    throw new Error("No model id provided for TTS pipeline");
  }

  // Resolve the per-module dtype for the active device.
  const deviceDtype = dtype?.[deviceName]?.model ?? "fp32";

  if (synthesizerPromise && loadedConfig?.device === deviceName && loadedConfig?.model === modelId) {
    return synthesizerPromise;
  }

  log(`loading ${modelId} on ${deviceName} (dtype ${deviceDtype})`);

  const pipelineOptions = {
    device: deviceName,
    dtype: deviceDtype,
    progress_callback: (progress) => {
      post({ type: "progress", ...progress });
    },
  };

  const attempt = pipeline("text-to-speech", modelId, pipelineOptions);

  // Register the promise immediately so a concurrent `synthesize` awaits the
  // same in-flight load instead of racing it.
  synthesizerPromise = attempt;

  try {
    await attempt;
  } catch (err) {
    if (deviceName === "webgpu") {
      log("WebGPU initialization failed, falling back to WASM/CPU", err);
      post({
        type: "fallback",
        from: "webgpu",
        to: "wasm",
        error: String(err?.message ?? err),
      });
      return loadPipeline({ ...options, device: "wasm" });
    }
    synthesizerPromise = null;
    throw err;
  }

  loadedDevice = deviceName;
  loadedConfig = { device: deviceName, model: modelId, dtype: deviceDtype };
  return synthesizerPromise;
}

async function synthesize({ id, text }) {
  if (!synthesizerPromise) {
    throw new Error("TTS pipeline is not initialized.");
  }

  const generation = ++currentGeneration;
  const started = performance.now();
  const synthesizer = await synthesizerPromise;
  const output = await synthesizer(text);

  // Discard stale results if cancel() was called in the meantime.
  if (generation !== currentGeneration) {
    log(`discarding stale synthesis result (generation ${generation} < ${currentGeneration})`);
    return null;
  }

  const inferenceMs = Math.round(performance.now() - started);

  // Transformers.js text-to-speech returns { audio: Float32Array, sampling_rate: number }
  const audio = output?.audio;
  const samplingRate = output?.sampling_rate ?? 16000;

  if (!audio || !(audio instanceof Float32Array)) {
    throw new Error("TTS pipeline returned invalid audio output");
  }

  log(`synthesized ${Math.round(audio.length / samplingRate)}s of audio in ${inferenceMs}ms on ${loadedDevice}`);

  return {
    id,
    audio,
    sampling_rate: samplingRate,
    device: loadedDevice,
    inferenceMs,
  };
}

self.addEventListener("message", async (event) => {
  const message = event.data;
  try {
    switch (message?.type) {
      case "init":
        await loadPipeline(message.options);
        post({ type: "ready", device: loadedDevice });
        break;

      case "synthesize":
        const result = await synthesize(message);
        if (result) {
          post({ type: "audio", ...result }, [result.audio.buffer]);
        }
        break;

      case "cancel":
        // Increment the generation counter so any in-flight synthesis result
        // is discarded when it arrives.
        ++currentGeneration;
        break;

      default:
        post({ type: "error", stage: "message", error: `Unknown message type: ${message?.type}` });
    }
  } catch (err) {
    log("error handling message", err);
    post({
      type: "error",
      stage: message?.type === "init" ? "init" : message?.type === "synthesize" ? "synthesize" : "message",
      error: String(err?.message ?? err),
    });
  }
});
