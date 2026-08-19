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
import { TTS_CONFIG } from "./tts_config.js";
import { createTTSEngine } from "./tts_engine.js";

const RECORD_BUTTON_BASE =
  "flex h-full w-full cursor-pointer items-center justify-center transition-colors duration-200 focus:outline-none";
const RECORD_BUTTON_LISTENING = "bg-primary text-primary-content";
const RECORD_BUTTON_IDLE = "bg-base-100 text-base-content";

// T0011/T0015 bounds: every async wait in the send -> speaking -> result chain
// is capped so the assistant can never stall indefinitely. The send timeout
// covers a hung fetch; the speaking watchdog covers an `onend` that never
// fires (the observed mobile hang / repeated-last-word symptom).
const SEND_TIMEOUT_MS = 15_000;
const SPEAK_MIN_MS = 5_000;
const SPEAK_MS_PER_CHAR = 150;
const SPEAK_MAX_MS = 30_000;
const SPEAK_AUDIO_BUFFER_MS = 2_000;

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
    this._speakWatchdog = null;
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
    this._stopSpeakWatchdog();
    this.ttsEngine?.cancel();
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
      tts: params.get("tts") || this.readCookie("soundai_tts") || TTS_CONFIG.engine,
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

  // Preloads the Whisper model and TTS engine in parallel so the user never
  // waits on either while talking. Whisper readiness is the gate for the
  // record button; the TTS engine is best-effort and falls back to native.
  async preload() {
    if (this.ready || this.preloading) return;
    this.preloading = true;
    this.lastForwardedProgress = 0;
    this.progress = 0;
    this.setState("loading");

    try {
      // Preload Whisper (the gate) and TTS engine in parallel
      await Promise.allSettled([
        this.ensureInit(),
        this.ensureTTSPreload()
      ]);
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

  // Preloads the TTS engine model in parallel with Whisper. Native engine
  // needs no model preload. On failure, replaces the engine with native.
  ensureTTSPreload() {
    if (this._ttsPreloadPromise) return this._ttsPreloadPromise;

    this._ttsPreloadPromise = this.detectDevice()
      .then((device) => {
        if (this.config.tts === "native") return;

        this.log(`preloading TTS engine: ${this.config.tts} on ${device}`);
        return this.ttsEngine.init(device);
      })
      .catch((err) => {
        console.warn("[soundai] TTS preload failed, falling back to native:", err?.message || err);
        this.ttsEngine = createTTSEngine("native");
        this.ttsEngine.init();
      });

    return this._ttsPreloadPromise;
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
  //
  // Mode dispatch (T0015):
  //   * "server" TTS engine  -> audio mode: one POST to /api/conversations/audio
  //     returns a WAV (LLM + server TTS in one round trip) that we play. A 503
  //     (server TTS model absent) falls back to text mode for this utterance.
  //   * native / local engine -> text mode: POST /api/transcriptions and speak
  //     the returned text with that engine.
  async sendTranscript(text) {
    if (!navigator.onLine) {
      this.sendNote = "Offline — transcript kept locally.";
      if (this.state === "sending") this.setState("result");
      return;
    }

    if (this.config.tts === "server") {
      await this.sendAudioMode(text);
    } else {
      await this.sendTextMode(text);
    }
  }

  async sendTextMode(text) {
    let ok = false;
    let responseData = null;

    try {
      const response = await this.fetchWithTimeout("/api/transcriptions", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text, language: this.config.language }),
      });
      if (response.ok) {
        responseData = await response.json();
        ok = true;
      }
    } catch (_err) {
      ok = false;
    }

    this.sendNote = ok ? null : "Couldn't reach the server — transcript kept locally.";

    if (ok && responseData && typeof responseData.response === "string" && responseData.response.trim() !== "") {
      this.speakText(responseData.response);
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

  async sendAudioMode(text) {
    let response;
    try {
      response = await this.fetchWithTimeout("/api/conversations/audio", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text, language: this.config.language }),
      });
    } catch (_err) {
      this.sendNote = "Couldn't reach the server — transcript kept locally.";
      if (this.state === "sending") this.setState("result");
      return;
    }

    if (response.status === 200) {
      const audio = await response.arrayBuffer();
      if (this.state !== "sending") return;
      const durationMs = parseInt(response.headers.get("x-tts-duration-ms") || "0", 10);
      this.sendNote = null;
      this.playServerAudio(audio, durationMs);
      return;
    }

    if (response.status === 503) {
      // Server TTS model absent: automatic one-time fallback to text mode with
      // a quiet note; never the error state.
      this.log("server audio unavailable (503); falling back to text mode");
      this.sendNote = "El servidor no pudo generar audio — respuesta en texto.";
      await this.fallbackToTextMode(text);
      return;
    }

    // 422/502/504 or any other status: quiet note, transcript stays.
    this.sendNote = "Couldn't reach the server — transcript kept locally.";
    if (this.state === "sending") this.setState("result");
  }

  // Text-mode fallback used when the audio endpoint reports the server TTS
  // model is absent: relay to /api/transcriptions and speak the reply with the
  // native engine (the server engine cannot synthesize locally).
  async fallbackToTextMode(text) {
    try {
      const response = await this.fetchWithTimeout("/api/transcriptions", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text, language: this.config.language }),
      });
      if (response.ok) {
        const data = await response.json();
        if (typeof data?.response === "string" && data.response.trim() !== "") {
          this.speakWithNative(data.response);
          return;
        }
      }
    } catch (_err) {
      // Quiet note already set; fall through to the result state below.
    }
    if (this.state === "sending") this.setState("result");
  }

  // Plays the server-synthesized WAV returned by /api/conversations/audio
  // through the server TTS engine's playback path, under the speaking watchdog.
  playServerAudio(arrayBuffer, durationMs = 0) {
    if (this.state !== "sending") return;
    if (typeof this.ttsEngine?.playWav !== "function") {
      // The server engine was replaced (e.g. preload fell back to native); the
      // WAV has no playback path — quiet note, never the error state.
      this.sendNote = "Speech playback is not available.";
      this.setState("result");
      return;
    }
    this.setState("speaking");
    this._startSpeakWatchdog(null, durationMs);

    this.ttsEngine.playWav(arrayBuffer, {
      onend: () => {
        this._stopSpeakWatchdog();
        if (this.state === "speaking") this.setState("result");
      },
      onerror: () => {
        this._stopSpeakWatchdog();
        if (this.state === "speaking") {
          this.sendNote = "Speech playback failed.";
          this.setState("result");
        }
      },
    });
  }

  // Speak the server-returned text through the pluggable TTS engine (native or
  // local). Falls back to native engine on local engine failure, then to a
  // quiet note if both fail. Never enters the error state (PRD §13).
  speakText(responseText) {
    // A new recording may have started while the fetch was in flight; never
    // speak a stale response over it or clobber the "listening" state.
    if (this.state !== "sending") return;

    if (!this.ttsEngine || !this.ttsEngine.isReady()) {
      // Try native fallback immediately if the configured engine is not ready.
      if (this.config.tts !== "native") {
        this.log("TTS engine not ready, falling back to native");
        this.ttsEngine = createTTSEngine("native");
        this.ttsEngine.init();
      }

      if (!this.ttsEngine.isReady()) {
        this.sendNote = "Speech synthesis is not available.";
        this.setState("result");
        return;
      }
    }

    this._speakVia(this.ttsEngine, responseText, (err) => {
      if (this.config.tts === "native") return false;
      // Try native fallback on synthesis failure.
      console.warn("[soundai] TTS synthesis failed, falling back to native:", err);
      this.ttsEngine = createTTSEngine("native");
      this.ttsEngine.init();
      return this.ttsEngine.isReady();
    });
  }

  // Speaks text with an explicit native engine (used by the audio-mode 503
  // fallback, where this.ttsEngine is the server engine and cannot synthesize).
  speakWithNative(responseText) {
    if (this.state !== "sending") return;
    const native = createTTSEngine("native");
    native.init();

    if (!native.isReady()) {
      this.sendNote = "Speech synthesis is not available.";
      this.setState("result");
      return;
    }

    this._speakVia(native, responseText, () => false);
  }

  // Shared speaking path: drives the state machine, arms the watchdog, and
  // routes onend/onerror. `fallback` is called with the error on synthesis
  // failure; if it returns true the fallback engine's speech is started.
  // Callers must verify the state before speaking; the recursive fallback
  // branch legitimately runs while still in "speaking".
  _speakVia(engine, text, fallback) {
    this.setState("speaking");
    this._startSpeakWatchdog(text);

    engine.speak(text, this.config.language, {
      onend: () => {
        this._stopSpeakWatchdog();
        if (this.state === "speaking") this.setState("result");
      },
      onerror: (err) => {
        if (this.state !== "speaking") return;
        this._stopSpeakWatchdog();

        if (fallback(err)) {
          this._speakVia(this.ttsEngine, text, () => false);
          return;
        }

        this.sendNote = "Speech playback failed.";
        this.setState("result");
      },
    });
  }

  // ------------------------------------------------------ send/speak watchdog

  // Bounds a fetch so the UI never sits in "sending" forever (T0011).
  fetchWithTimeout(url, options = {}) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), SEND_TIMEOUT_MS);
    return fetch(url, { ...options, signal: controller.signal }).finally(() => clearTimeout(timer));
  }

  _startSpeakWatchdog(text, durationMs = 0) {
    this._stopSpeakWatchdog();
    let budget;
    if (durationMs > 0) {
      // Audio mode: the server reports the exact playback length; allow a
      // small buffer so a legitimate long WAV is never cut short.
      budget = durationMs + SPEAK_AUDIO_BUFFER_MS;
    } else {
      // Text mode (T0011): generous upper bound derived from the text length.
      budget = Math.min(
        SPEAK_MAX_MS,
        Math.max(SPEAK_MIN_MS, (text?.length || 0) * SPEAK_MS_PER_CHAR)
      );
    }
    this._speakWatchdog = setTimeout(() => {
      if (this.state !== "speaking") return;
      console.warn("[soundai] speaking timed out; forced result");
      this.ttsEngine?.cancel();
      this.sendNote = "Speech playback did not finish.";
      this.setState("result");
    }, budget);
  }

  _stopSpeakWatchdog() {
    if (this._speakWatchdog) {
      clearTimeout(this._speakWatchdog);
      this._speakWatchdog = null;
    }
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

    // Stop any ongoing speech synthesis so the user can interrupt mid-speech,
    // and cancel the speaking watchdog so a stray timer cannot clobber the new
    // "listening" state (T0011).
    this._stopSpeakWatchdog();
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