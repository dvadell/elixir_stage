// Main-thread controller for the voice assistant.
//
// Responsibilities:
//   * Detect WebGPU availability (with WASM/CPU fallback).
//   * Capture microphone audio as raw PCM (only while the user holds the button).
//   * Resample captured audio to 16 kHz mono so Whisper can consume it.
//   * Drive the Whisper worker, reusing the loaded model across utterances.
//   * Keep the LiveView in sync (idle / listening / transcribing / error / result)
//     and log every transcript to the browser console.
//
// Raw microphone audio never leaves the browser: transcription runs locally
// through `whisper_worker.js` (Transformers.js + Whisper) on WebGPU or WASM.

import { WHISPER_CONFIG } from "./whisper_config.js";

export const VoiceAssistant = {
  mounted() {
    this.state = "idle";
    this.worker = null;
    this.workerInit = null;
    this.device = null;
    this.recording = false;
    this.recordingStarted = 0;
    this.sampleRate = 16000;
    this.audioChunks = [];
    this.audioContext = null;
    this.sourceNode = null;
    this.processorNode = null;
    this.stream = null;
    this.transcribeSeq = 0;
    this.lastForwardedProgress = 0;
    this.ready = false;
    this.preloading = false;
    this.config = this.resolveConfig();

    this.onPointerDown = this.onPointerDown.bind(this);
    this.onPointerUp = this.onPointerUp.bind(this);

    this.el.addEventListener("pointerdown", this.onPointerDown);
    this.el.addEventListener("pointerup", this.onPointerUp);
    this.el.addEventListener("pointercancel", this.onPointerUp);

    // Load the selected model before the microphone button is shown, so using
    // the assistant never waits on the download.
    this.preload();
  },

  destroyed() {
    this.el.removeEventListener("pointerdown", this.onPointerDown);
    this.el.removeEventListener("pointerup", this.onPointerUp);
    this.el.removeEventListener("pointercancel", this.onPointerUp);
    this.teardownAudio();
    if (this.worker) {
      this.worker.terminate();
      this.worker = null;
    }
  },

  // ---------------------------------------------------------------- helpers

  log(...args) {
    console.log("[soundai]", ...args);
  },

  // The model/language can be overridden per session for benchmarking via URL
  // search params, or persistently via a cookie written by the /settings page,
  // so the browser remembers the choice across visits.
  // Precedence: URL param > saved cookie > committed WHISPER_CONFIG default.
  resolveConfig() {
    const params = new URLSearchParams(window.location.search);
    return {
      model: params.get("model") || this.readCookie("soundai_model") || WHISPER_CONFIG.model,
      language:
        params.get("language") || this.readCookie("soundai_language") || WHISPER_CONFIG.language,
    };
  },

  readCookie(name) {
    const prefix = `${name}=`;
    for (const cookie of document.cookie.split("; ")) {
      if (cookie.startsWith(prefix)) {
        return decodeURIComponent(cookie.slice(prefix.length));
      }
    }
    return null;
  },

  setState(state) {
    this.state = state;
  },

  pushState(payload) {
    this.pushEvent("voice_state", payload);
  },

  fail(message, details) {
    console.error("[soundai] error:", message, details ?? "");
    this.setState("error");
    this.teardownAudio();
    this.pushState({ state: "error", error: message, device: this.device });
  },

  friendlyMicError(err) {
    const name = err?.name;
    if (name === "NotAllowedError" || name === "SecurityError") {
      return "Microphone access was denied. Allow microphone access and try again.";
    }
    if (name === "NotFoundError" || name === "OverconstrainedError" || name === "DevicesNotFoundError") {
      return "No microphone was found on this device.";
    }
    if (name === "NotReadableError") {
      return "The microphone is already in use by another application.";
    }
    return err?.message || "Unable to access the microphone.";
  },

  // --------------------------------------------------------------- whisper

  ensureWorker() {
    if (this.worker) return this.worker;

    const worker = new Worker("/assets/js/whisper_worker.js", { type: "module" });
    worker.addEventListener("message", (event) => this.onWorkerMessage(event.data));
    worker.addEventListener("error", (event) => {
      console.error("[soundai] whisper worker crashed:", event.message || event);
      this.fail("The speech recognition worker failed to start.");
    });
    this.worker = worker;
    return worker;
  },

  async detectDevice() {
    if (navigator.gpu) {
      try {
        const adapter = await navigator.gpu.requestAdapter();
        if (adapter) {
          this.log("WebGPU is available");
          return "webgpu";
        }
      } catch (err) {
        console.warn("[soundai] WebGPU detection failed:", err);
      }
    }
    this.log("WebGPU is unavailable, using WASM/CPU");
    return "wasm";
  },

  // Preloads the Whisper model (the one selected in /settings, or the config
  // default) before the record button becomes interactive. Model loading is
  // kept separate from usage so the user never waits on it while talking.
  async preload() {
    if (this.ready || this.preloading) return;
    this.preloading = true;
    this.lastForwardedProgress = 0;
    this.setState("loading");
    this.pushState({ state: "loading", progress: 0 });
    try {
      await this.ensureInit();
    } catch (_err) {
      // fail() has already surfaced the error; a retry is handled on
      // pointerdown since the microphone button is only shown once ready.
    } finally {
      this.preloading = false;
    }
  },

  // Initializes the Whisper pipeline once and reuses it for every utterance.
  ensureInit() {
    if (this.workerInit) return this.workerInit;

    this.workerInit = this.detectDevice()
      .then((device) => {
        this.device = device;
        this.log(`device: ${device}, model: ${this.config.model}, language: ${this.config.language}`);
        const options = {
          device,
          model: this.config.model,
          language: this.config.language,
          dtype: WHISPER_CONFIG.dtype,
        };
        this.ensureWorker().postMessage({ type: "init", options });
      })
      .catch((err) => {
        this.workerInit = null;
        this.fail(`Unable to initialize Whisper: ${err?.message || err}`);
        throw err;
      });

    return this.workerInit;
  },

  onWorkerMessage(message) {
    switch (message?.type) {
      case "progress":
        this.onModelProgress(message);
        break;
      case "ready":
        this.log(`Whisper ready on ${message.device}`);
        this.ready = true;
        if (this.state === "loading") {
          this.setState("idle");
          this.pushState({ state: "idle" });
        } else if (this.state === "listening" || this.state === "transcribing") {
          // Hide the "Preparing Whisper…" hint now that loading finished.
          this.pushState({ state: this.state, progress: 100 });
        }
        break;
      case "fallback":
        this.device = message.to;
        this.log(`Whisper fell back from ${message.from} to ${message.to} (${message.error})`);
        break;
      case "result":
        this.handleResult(message);
        break;
      case "error":
        if (message.stage === "init") {
          this.workerInit = null;
          this.ready = false;
        }
        this.fail(message.error || "Speech recognition failed.", { stage: message.stage });
        break;
      default:
        console.warn("[soundai] unknown worker message:", message);
    }
  },

  onModelProgress(progress) {
    const percent = Math.round(progress.progress ?? 0);
    if (percent !== this.lastForwardedProgress && percent % 2 === 0) {
      this.lastForwardedProgress = percent;
      this.log(`Whisper model download: ${percent}%`);
    }
    // Surface coarse download progress so the UI can show it on the loading
    // screen or while the first transcription is warming up.
    const overall = progress.status === "progress_total" ? Math.round(progress.progress ?? 0) : percent;
    if (
      (this.state === "loading" || this.state === "listening" || this.state === "transcribing") &&
      overall > 0 &&
      overall < 100
    ) {
      this.pushState({ state: this.state, progress: overall });
    }
  },

  handleResult(message) {
    const text = (message.text || "").trim();

    if (!text) {
      this.log("no speech detected");
      this.setState("idle");
      this.pushState({ state: "idle" });
      return;
    }

    this.log("transcript:", text);
    this.log("transcription", {
      device: message.device,
      inferenceMs: message.inferenceMs,
    });
    this.setState("result");
    this.pushState({ state: "result", transcript: text, device: message.device });
  },

  // ----------------------------------------------------------- microphone

  async startCapture() {
    if (!navigator.mediaDevices || typeof navigator.mediaDevices.getUserMedia !== "function") {
      throw new Error("This browser does not support microphone access.");
    }

    this.stream = await navigator.mediaDevices.getUserMedia({ audio: true });

    const AudioContextCtor = window.AudioContext || window.webkitAudioContext;
    if (!AudioContextCtor) {
      throw new Error("This browser does not support the Web Audio API.");
    }

    this.audioContext = new AudioContextCtor();
    this.sampleRate = this.audioContext.sampleRate || 16000;
    this.audioChunks = [];
    this.recordingStarted = performance.now();

    this.sourceNode = this.audioContext.createMediaStreamSource(this.stream);
    this.processorNode = this.audioContext.createScriptProcessor(4096, 1, 1);
    this.processorNode.onaudioprocess = (event) => {
      const input = event.inputBuffer.getChannelData(0);
      this.audioChunks.push(new Float32Array(input));
    };

    // Route audio to a silent sink so the ScriptProcessor keeps firing
    // without playing the microphone back through the speakers.
    const silent = this.audioContext.createMediaStreamDestination();
    this.sourceNode.connect(this.processorNode);
    this.processorNode.connect(silent);

    if (this.audioContext.state === "suspended") {
      await this.audioContext.resume();
    }
  },

  async stopCapture() {
    const duration = performance.now() - this.recordingStarted;
    const chunks = this.audioChunks;
    this.teardownAudio();

    if (chunks.length === 0 || duration < WHISPER_CONFIG.minUtteranceMs) {
      return null;
    }

    const samples = concatAudio(chunks);
    if (this.sampleRate === 16000) {
      return samples;
    }
    return resampleAudio(samples, this.sampleRate, 16000);
  },

  teardownAudio() {
    if (this.sourceNode) {
      try {
        this.sourceNode.disconnect();
      } catch (_err) {
        // already disconnected
      }
      this.sourceNode = null;
    }
    if (this.processorNode) {
      try {
        this.processorNode.disconnect();
      } catch (_err) {
        // already disconnected
      }
      this.processorNode = null;
    }
    if (this.audioContext) {
      this.audioContext.close().catch(() => {});
      this.audioContext = null;
    }
    if (this.stream) {
      this.stream.getTracks().forEach((track) => track.stop());
      this.stream = null;
    }
  },

  // ------------------------------------------------------------ interactions

  async onPointerDown(event) {
    event.preventDefault();
    // The hook sits on the page container, so skip presses that start on the
    // settings link (or any other anchor) to avoid starting a recording when
    // the user navigates away.
    if (event.target.closest("a")) return;
    if (this.recording || this.state === "transcribing") return;

    if (this.state === "loading" || (this.state === "error" && !this.ready)) {
      // The model is still loading (or failed to load): (re)start the preload
      // instead of recording, since the microphone button is only enabled once
      // the model is ready.
      this.preload();
      return;
    }

    this.recording = true;
    this.setState("listening");
    this.pushState({ state: "listening", progress: 0 });

    // Model initialization is already preloaded; this call is a no-op safety
    // net in case the ready message was missed.
    this.ensureInit().catch(() => {
      // Error is already surfaced by ensureInit/fail; keep recording so the
      // user can finish their utterance.
    });

    try {
      await this.startCapture();
    } catch (err) {
      this.recording = false;
      this.fail(this.friendlyMicError(err));
    }
  },

  async onPointerUp(event) {
    event.preventDefault();
    if (!this.recording) return;
    this.recording = false;

    let audio;
    try {
      audio = await this.stopCapture();
    } catch (err) {
      return this.fail(`Failed to stop recording: ${err?.message || err}`);
    }

    if (!audio) {
      this.setState("idle");
      this.pushState({ state: "idle" });
      this.log("utterance too short, skipping transcription");
      return;
    }

    this.setState("transcribing");
    this.pushState({ state: "transcribing" });
    this.transcribe(audio);
  },

  async transcribe(audio) {
    try {
      await this.ensureInit();
      const id = ++this.transcribeSeq;
      this.ensureWorker().postMessage(
        { type: "transcribe", id, audio, language: this.config.language },
        [audio.buffer],
      );
    } catch (err) {
      this.fail(`Transcription failed: ${err?.message || err}`);
    }
  },
};

// ---------------------------------------------------------------------------

function concatAudio(chunks) {
  const totalLength = chunks.reduce((acc, chunk) => acc + chunk.length, 0);
  const result = new Float32Array(totalLength);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.length;
  }
  return result;
}

// High-quality sample-rate conversion via the Web Audio API. Whisper expects
// 16 kHz mono float32 samples.
async function resampleAudio(samples, sourceRate, targetRate) {
  if (sourceRate === targetRate) return samples;

  const AudioContextCtor = window.OfflineAudioContext || window.webkitOfflineAudioContext;
  if (!AudioContextCtor) {
    throw new Error("This browser does not support audio resampling (OfflineAudioContext).");
  }

  const length = Math.max(1, Math.round((samples.length / sourceRate) * targetRate));
  const context = new AudioContextCtor(1, length, targetRate);
  const buffer = context.createBuffer(1, samples.length, sourceRate);
  buffer.getChannelData(0).set(samples);

  const source = context.createBufferSource();
  source.buffer = buffer;
  source.connect(context.destination);
  source.start(0);

  const rendered = await context.startRendering();
  return rendered.getChannelData(0);
}