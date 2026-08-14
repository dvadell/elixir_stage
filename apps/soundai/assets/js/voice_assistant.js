// Main-thread controller for the voice assistant.
//
// Responsibilities:
//   * Detect WebGPU availability (with WASM/CPU fallback).
//   * Capture microphone audio as raw PCM (only while the user holds the button).
//   * Resample captured audio to 16 kHz mono so Whisper can consume it.
//   * Drive the Whisper worker, reusing the loaded model across utterances.
//   * Render the whole assistant UI (loading / listening / transcribing /
//     error / result) directly in the browser.
//
// This module is offline-first: raw microphone audio never leaves the browser.
// Transcription runs locally through `whisper_worker.js` (Transformers.js +
// Whisper) on WebGPU or WASM, and as long as the page shell and the speech
// model are already cached, STT keeps working with no network at all. The only
// server communication is the best-effort POST of the transcript text to
// `/api/transcriptions`; the server's `response` (the same text today, the LLM
// reply later) is spoken aloud through the pluggable TTS engine
// (`tts_engine.js`), which currently routes to the native Web Speech API.

import { WHISPER_CONFIG } from "./whisper_config.js";
import { createTTSEngine } from "./tts_engine.js";

const RECORD_BUTTON_BASE =
  "flex h-full w-full cursor-pointer items-center justify-center transition-colors duration-200 focus:outline-none";
const RECORD_BUTTON_LISTENING = "bg-primary text-primary-content";
const RECORD_BUTTON_IDLE = "bg-base-100 text-base-content";

export function mountVoiceAssistant() {
  const el = document.getElementById("voice-assistant");
  if (!el || el.dataset.vaMounted) return;
  el.dataset.vaMounted = "true";

  const controller = new VoiceAssistantController(el);
  controller.start();
}

class VoiceAssistantController {
  constructor(el) {
    this.el = el;
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
    this.transcript = null;
    this.error = null;
    this.progress = null;
    this.sendNote = null;
    this.config = this.resolveConfig();
    this.ttsEngine = createTTSEngine(this.config.tts);

    this.onPointerDown = this.onPointerDown.bind(this);
    this.onPointerUp = this.onPointerUp.bind(this);

    // DOM nodes driven by the state machine.
    this.ui = {
      loadingScreen: document.getElementById("model-loading"),
      recordButton: document.getElementById("record-button"),
      voiceLabel: document.getElementById("voice-label"),
      listeningPing: document.getElementById("listening-ping"),
      listeningDot: document.getElementById("listening-dot"),
      recordIcon: document.getElementById("record-icon"),
      preparingHint: document.getElementById("preparing-hint"),
      preparingProgress: document.getElementById("preparing-progress"),
      loadingProgress: document.getElementById("model-loading-progress"),
      loadingProgressValue: document.getElementById("model-loading-progress-value"),
      resultBox: document.getElementById("voice-result"),
      resultBoxInner: document.getElementById("voice-result-box"),
      errorText: document.getElementById("voice-error"),
      transcriptText: document.getElementById("voice-transcript"),
      sendStatus: document.getElementById("voice-send-status"),
    };
  }

  start() {
    this.el.addEventListener("pointerdown", this.onPointerDown);
    this.el.addEventListener("pointerup", this.onPointerUp);
    this.el.addEventListener("pointercancel", this.onPointerUp);

    // Load the selected model before the microphone button is shown, so using
    // the assistant never waits on the download.
    this.setState("loading");
    this.preload();
  }

  stop() {
    this.el.removeEventListener("pointerdown", this.onPointerDown);
    this.el.removeEventListener("pointerup", this.onPointerUp);
    this.el.removeEventListener("pointercancel", this.onPointerUp);
    this.teardownAudio();
    if (this.worker) {
      this.worker.terminate();
      this.worker = null;
    }
  }

  // ---------------------------------------------------------------- helpers

  log(...args) {
    console.log("[soundai]", ...args);
  }

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
      tts: params.get("tts") || this.readCookie("soundai_tts") || "native",
    };
  }

  readCookie(name) {
    const prefix = `${name}=`;
    for (const cookie of document.cookie.split("; ")) {
      if (cookie.startsWith(prefix)) {
        return decodeURIComponent(cookie.slice(prefix.length));
      }
    }
    return null;
  }

  setState(state) {
    this.state = state;
    this.render();
  }

  fail(message, details) {
    console.error("[soundai] error:", message, details ?? "");
    this.error = message;
    this.transcript = null;
    this.sendNote = null;
    this.setState("error");
    this.teardownAudio();
  }

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
  }

  // ------------------------------------------------------------- ui rendering

  setHidden(node, hidden) {
    if (node) node.hidden = hidden;
  }

  render() {
    const ui = this.ui;
    const state = this.state;
    const loading = state === "loading";
    const listening = state === "listening";
    const transcribing = state === "transcribing";

    this.setHidden(ui.loadingScreen, !loading);

    if (!loading) {
      this.setHidden(ui.recordButton, false);
      this.renderRecordButton(listening);
      ui.voiceLabel.textContent = this.voiceLabel();
      this.setHidden(ui.listeningPing, !listening);
      this.setHidden(ui.listeningDot, !listening);
      if (ui.recordIcon) {
        ui.recordIcon.classList.toggle("scale-110", listening);
      }
      this.renderPreparingHint(listening || transcribing);
    } else {
      this.setHidden(ui.recordButton, true);
      this.renderLoadingProgress();
    }

    this.renderResult();
  }

  renderRecordButton(listening) {
    const button = this.ui.recordButton;
    if (!button) return;
    button.className = [
      RECORD_BUTTON_BASE,
      listening ? RECORD_BUTTON_LISTENING : RECORD_BUTTON_IDLE,
    ].join(" ");
  }

  renderLoadingProgress() {
    const value = this.progress;
    const visible = typeof value === "number" && value > 0 && value < 100;
    this.setHidden(this.ui.loadingProgress, !visible);
    if (visible && this.ui.loadingProgressValue) {
      this.ui.loadingProgressValue.textContent = String(value);
    }
  }

  renderPreparingHint(active) {
    const value = this.progress;
    const visible = active && typeof value === "number" && value > 0 && value < 100;
    this.setHidden(this.ui.preparingHint, !visible);
    if (visible && this.ui.preparingProgress) {
      this.ui.preparingProgress.textContent = String(value);
    }
  }

  renderResult() {
    const error = this.error;
    const transcript = this.transcript;
    const visible = Boolean(error || transcript);
    this.setHidden(this.ui.resultBox, !visible);
    if (!visible) return;

    const errorMode = Boolean(error);
    this.setHidden(this.ui.errorText, !errorMode);
    this.setHidden(this.ui.transcriptText, errorMode);
    if (errorMode) {
      this.ui.errorText.textContent = error;
      this.ui.resultBoxInner.className =
        "w-full max-w-2xl rounded-box border border-error/40 bg-base-100/90 px-6 py-5 text-center shadow-lg backdrop-blur";
    } else {
      this.ui.transcriptText.textContent = transcript;
      this.ui.resultBoxInner.className =
        "w-full max-w-2xl rounded-box border border-base-300 bg-base-100/90 px-6 py-5 text-center shadow-lg backdrop-blur";
    }

    // Non-blocking send status: "Sending…" while the transcript is in flight,
    // a quiet offline notice after a failed send, nothing on success.
    const note = errorMode ? null : this.sendNote;
    this.setHidden(this.ui.sendStatus, !note);
    if (note) {
      this.ui.sendStatus.textContent = note;
    }
  }

  voiceLabel() {
    switch (this.state) {
      case "listening":
        return "Listening…";
      case "transcribing":
        return "Transcribing…";
      case "sending":
        return "Sending…";
      case "speaking":
        return "Speaking…";
      case "result":
        return "Tap to talk again";
      case "error":
        return "Tap to retry";
      default:
        return "Hold to talk";
    }
  }

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
  }

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
  }

  // Preloads the Whisper model (the one selected in /settings, or the config
  // default) before the record button becomes interactive. Model loading is
  // kept separate from usage so the user never waits on it while talking.
  async preload() {
    if (this.ready || this.preloading) return;
    this.preloading = true;
    this.lastForwardedProgress = 0;
    this.progress = 0;
    this.setState("loading");
    try {
      await this.ensureInit();
    } catch (_err) {
      // fail() has already surfaced the error; a retry is handled on
      // pointerdown since the microphone button is only shown once ready.
    } finally {
      this.preloading = false;
    }
  }

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
  }

  onWorkerMessage(message) {
    switch (message?.type) {
      case "progress":
        this.onModelProgress(message);
        break;
      case "ready":
        this.log(`Whisper ready on ${message.device}`);
        this.ready = true;
        this.progress = 100;
        if (this.state === "loading") {
          this.error = null;
          this.setState("idle");
        } else if (this.state === "listening" || this.state === "transcribing") {
          // Hide the "Preparing Whisper…" hint now that loading finished.
          this.render();
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
  }

  onModelProgress(progress) {
    const percent = Math.round(progress.progress ?? 0);
    if (percent !== this.lastForwardedProgress && percent % 2 === 0) {
      this.lastForwardedProgress = percent;
      this.log(`Whisper model download: ${percent}%`);
    }
    // Surface coarse download progress so the UI can show it on the loading
    // screen or while the first transcription is warming up.
    const overall = progress.status === "progress_total" ? Math.round(progress.progress ?? 0) : percent;
    if (overall > 0 && overall < 100) {
      this.progress = overall;
      this.render();
    }
  }

  handleResult(message) {
    const text = (message.text || "").trim();

    if (!text) {
      this.log("no speech detected");
      this.error = null;
      this.transcript = null;
      this.setState("idle");
      return;
    }

    this.log("transcript:", text);
    this.log("transcription", {
      device: message.device,
      inferenceMs: message.inferenceMs,
    });
    this.transcript = text;
    this.error = null;
    this.sendNote = "Sending…";
    this.setState("sending");
    this.sendTranscript(text);
  }

  // Best-effort send of the transcript to the backend. Only the text travels
  // over the network; raw microphone audio never leaves the browser. The UI
  // must never depend on this: the transcript stays visible and the send fails
  // quietly (or is skipped entirely) when offline.
  async sendTranscript(text) {
    const payload = { text, language: this.config.language };
    let ok = false;
    let responseData = null;

    if (navigator.onLine) {
      try {
        const response = await fetch("/api/transcriptions", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload),
        });
        if (response.ok) {
          responseData = await response.json();
          ok = true;
        }
      } catch (_err) {
        ok = false;
      }
    }

    this.sendNote = ok
      ? null
      : navigator.onLine
        ? "Couldn't reach the server — transcript kept locally."
        : "Offline — transcript kept locally.";

    if (ok && responseData && typeof responseData.response === "string" && responseData.response.trim() !== "") {
      this.speakResponse(responseData.response);
    } else if (this.state === "sending") {
      if (ok) {
        // A successful send with no speakable response (e.g. empty text): keep
        // the transcript with a quiet note, never the error state.
        this.sendNote = "No response from the server — transcript kept locally.";
      }
      this.setState("result");
    } else {
      this.render();
    }
  }

  // Speak the server-returned text through the pluggable TTS engine.
  // Falls back to showing the transcript with a quiet note if the engine
  // is unavailable or the response is empty.
  speakResponse(responseText) {
    // A new recording may have started while the fetch was in flight; never
    // speak a stale response over it or clobber the "listening" state.
    if (this.state !== "sending") return;

    if (!this.ttsEngine || !this.ttsEngine.isReady()) {
      this.sendNote = "Speech synthesis is not available.";
      this.setState("result");
      return;
    }

    this.setState("speaking");

    this.ttsEngine.speak(
      responseText,
      this.config.language,
      {
        onend: () => {
          if (this.state === "speaking") {
            this.setState("result");
          }
        },
        onerror: () => {
          if (this.state === "speaking") {
            this.sendNote = "Speech playback failed.";
            this.setState("result");
          }
        },
      }
    );
  }

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
  }

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
  }

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
  }

  // ------------------------------------------------------------ interactions

  async onPointerDown(event) {
    event.preventDefault();
    // The controller sits on the page container, so skip presses that start on
    // the settings link (or any other anchor) to avoid starting a recording
    // when the user navigates away.
    if (event.target.closest("a")) return;
    if (this.recording || this.state === "transcribing") return;

    // Stop any ongoing speech synthesis so the user can interrupt mid-speech
    this.ttsEngine?.cancel();

    if (this.state === "loading" || (this.state === "error" && !this.ready)) {
      // The model is still loading (or failed to load): (re)start the preload
      // instead of recording, since the microphone button is only enabled once
      // the model is ready.
      this.preload();
      return;
    }

    this.recording = true;
    this.progress = 0;
    this.sendNote = null;
    this.setState("listening");

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
  }

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
      this.error = null;
      this.transcript = null;
      this.setState("idle");
      this.log("utterance too short, skipping transcription");
      return;
    }

    this.setState("transcribing");
    this.transcribe(audio);
  }

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
  }
}

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