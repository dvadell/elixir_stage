// Whisper speech-to-text worker.
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

export const DEFAULT_MODEL = "onnx-community/whisper-base";

env.allowLocalModels = false;
// Cache the model weights and the WASM runtime binary in the browser Cache
// Storage so subsequent sessions do not re-download them.
env.useBrowserCache = true;
env.useWasmCache = true;
env.logLevel = LogLevel.WARNING;

let pipelinePromise = null;
let loadedDevice = null;
let loadedConfig = null;

function log(...args) {
  console.log("[soundai:whisper-worker]", ...args);
}

function post(message) {
  self.postMessage(message);
}

async function loadPipeline(options) {
  const deviceName = options?.device || "wasm";
  const modelId = options?.model || DEFAULT_MODEL;
  const language = options?.language;

  // Resolve the per-module dtype for the active device (the main thread sends
  // a per-device map so a WebGPU→WASM fallback picks the right files too).
  const dtype = options?.dtype?.[deviceName] ?? {
    encoder_model: "fp32",
    decoder_model_merged: "q8",
  };

  if (pipelinePromise && loadedConfig?.device === deviceName && loadedConfig?.model === modelId) {
    return pipelinePromise;
  }

  log(
    `loading ${modelId} on ${deviceName} (encoder ${dtype.encoder_model}, decoder ${dtype.decoder_model_merged})`,
  );

  const pipelineOptions = {
    device: deviceName,
    dtype,
    progress_callback: (progress) => {
      post({ type: "progress", ...progress });
    },
  };

  const attempt = pipeline("automatic-speech-recognition", modelId, pipelineOptions);

  // Register the promise immediately so a concurrent `transcribe` awaits the
  // same in-flight load instead of racing it.
  pipelinePromise = attempt;

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
    pipelinePromise = null;
    throw err;
  }

  loadedDevice = deviceName;
  loadedConfig = { device: deviceName, model: modelId, language, dtype };
  return pipelinePromise;
}

async function transcribe({ id, audio, language }) {
  if (!pipelinePromise) {
    throw new Error("Whisper pipeline is not initialized.");
  }

  const started = performance.now();
  const pipe = await pipelinePromise;
  const output = await pipe(audio, {
    task: "transcribe",
    language: language || "spanish",
    chunk_length_s: 30,
    stride_length_s: 5,
    return_timestamps: false,
  });
  const inferenceMs = Math.round(performance.now() - started);

  const text = typeof output?.text === "string" ? output.text.trim() : "";
  log(`transcribed ${Math.round(audio.length / 16_000)}s of audio in ${inferenceMs}ms on ${loadedDevice}`);

  return { id, text, device: loadedDevice, inferenceMs };
}

self.addEventListener("message", async (event) => {
  const message = event.data;
  try {
    switch (message?.type) {
      case "init":
        await loadPipeline(message.options);
        post({ type: "ready", device: loadedDevice });
        break;
      case "transcribe":
        const result = await transcribe(message);
        post({ type: "result", ...result });
        break;
      default:
        post({ type: "error", stage: "message", error: `Unknown message type: ${message?.type}` });
    }
  } catch (err) {
    log("error handling message", err);
    post({
      type: "error",
      stage: message?.type === "init" ? "init" : message?.type === "transcribe" ? "transcribe" : "message",
      error: String(err?.message ?? err),
    });
  }
});