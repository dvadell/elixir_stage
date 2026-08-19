// Pluggable TTS engine abstraction.
//
// Each engine implements:
//   init()       -> Promise    (preload voices/models)
//   isReady()    -> bool       (engine ready to speak)
//   speak(text, language, {onend, onerror})  -> starts playback
//   cancel()     -> void       (stop in-flight playback immediately)
//
// The native engine wraps speechSynthesis. Future engines (local Transformers.js,
// server-side TTS) are added by registering a class here — no changes to
// voice_assistant.js or the UI are required.

import { TTS_CONFIG } from "./tts_config.js";

// ---------------------------------------------------------------------------
// Native TTS engine (Web Speech API)
// ---------------------------------------------------------------------------

class NativeTTSEngine {
  constructor() {
    this._ready = typeof window.speechSynthesis !== "undefined";
    this._initPromise = this._init();
  }

  async _init() {
    if (!this._ready) return;

    // Warm the voice list so the first utterance is not delayed.
    // getVoices() can return an empty array on first call; the 'voiceschanged'
    // event fires asynchronously. We wait for a non-empty list or a timeout.
    return new Promise((resolve) => {
      const check = () => {
        const voices = window.speechSynthesis.getVoices();
        if (voices.length > 0) {
          this._ready = true;
          resolve();
          return;
        }
        // Try again on the next event loop tick or voiceschanged event.
        window.speechSynthesis.addEventListener("voiceschanged", check, { once: true });
        setTimeout(() => {
          this._ready = true;
          resolve();
        }, 2000);
      };
      check();
    });
  }

  init() {
    return this._initPromise;
  }

  isReady() {
    return this._ready;
  }

  speak(text, language, options = {}) {
    const { onend, onerror } = options;

    if (!this._ready) {
      if (onerror) onerror(new Error("Speech synthesis not available"));
      return;
    }

    window.speechSynthesis.cancel();

    const utterance = new SpeechSynthesisUtterance(text);
    const langTag = languageToBCP47(language);
    utterance.lang = langTag;

    // Prefer a voice matching the target language.
    const voices = window.speechSynthesis.getVoices();
    const matchingVoice = voices.find(
      (v) => v.lang.toLowerCase().startsWith(langTag.toLowerCase())
    );
    if (matchingVoice) utterance.voice = matchingVoice;

    utterance.onend = () => {
      if (onend) onend();
    };

    utterance.onerror = (event) => {
      if (onerror) onerror(event);
    };

    window.speechSynthesis.speak(utterance);
  }

  cancel() {
    if (this._ready) {
      window.speechSynthesis.cancel();
    }
  }
}

// ---------------------------------------------------------------------------
// Transformers.js TTS engine (local VITS model in Web Worker)
// ---------------------------------------------------------------------------

class TransformersTTSEngine {
  constructor(modelId) {
    this._modelId = modelId;
    this._ready = false;
    this._worker = null;
    this._audioContext = null;
    this._sourceNode = null;
    this._initPromise = null;
    this._synthesizeSeq = 0;
    this._speakListener = null;
  }

  init(device) {
    if (this._initPromise) return this._initPromise;

    const modelConfig = TTS_CONFIG.getModelConfig(this._modelId);
    this._initPromise = this._doInit(device, modelConfig);
    return this._initPromise;
  }

  async _doInit(device, modelConfig) {
    this._worker = new Worker("/assets/js/tts_worker.js", { type: "module" });

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        reject(new Error("TTS model initialization timed out"));
      }, 60_000);

      this._worker.addEventListener("message", (event) => {
        const msg = event.data;
        switch (msg.type) {
          case "ready":
            clearTimeout(timeout);
            this._ready = true;
            console.log("[soundai] TTS worker ready on", msg.device, "for", this._modelId);
            resolve();
            break;

          case "fallback":
            console.warn("[soundai] TTS fell back from", msg.from, "to", msg.to, ":", msg.error);
            break;

          case "error":
            clearTimeout(timeout);
            reject(new Error(msg.error));
            break;
        }
      });

      this._worker.addEventListener("error", (event) => {
        clearTimeout(timeout);
        reject(new Error(event.message || "TTS worker crashed"));
      });

      this._worker.postMessage({
        type: "init",
        options: {
          device,
          model: this._modelId,
          dtype: modelConfig.dtype,
        },
      });
    });
  }

  isReady() {
    return this._ready;
  }

  speak(text, language, options = {}) {
    const { onend, onerror } = options;

    if (!this._ready || !this._worker) {
      if (onerror) onerror(new Error("Transformers TTS engine not ready"));
      return;
    }

    this._stopPlayback();
    this._worker.postMessage({ type: "cancel" });

    if (this._speakListener) {
      this._worker.removeEventListener("message", this._speakListener);
    }

    const id = ++this._synthesizeSeq;
    this._worker.postMessage({ type: "synthesize", id, text });

    const handleAudio = (event) => {
      const msg = event.data;
      if (msg.type === "audio" && msg.id === id) {
        this._worker.removeEventListener("message", handleAudio);
        this._speakListener = null;
        this._playAudio(msg.audio, msg.sampling_rate, onend, onerror);
      } else if (msg.type === "error") {
        this._worker.removeEventListener("message", handleAudio);
        this._speakListener = null;
        if (onerror) onerror(new Error(msg.error));
      }
    };
    this._speakListener = handleAudio;
    this._worker.addEventListener("message", handleAudio);
  }

  _playAudio(audioData, samplingRate, onend, onerror) {
    try {
      if (!this._audioContext || this._audioContext.state === "closed") {
        this._audioContext = new (window.AudioContext || window.webkitAudioContext)();
      }

      const ctx = this._audioContext;
      if (ctx.state === "suspended") {
        ctx.resume();
      }

      const buffer = ctx.createBuffer(1, audioData.length, samplingRate);
      buffer.getChannelData(0).set(audioData);

      const source = ctx.createBufferSource();
      source.buffer = buffer;
      source.connect(ctx.destination);
      this._sourceNode = source;

      source.onended = () => {
        this._sourceNode = null;
        if (onend) onend();
      };

      source.onerror = () => {
        this._sourceNode = null;
        if (onerror) onerror(new Error("Audio playback failed"));
      };

      source.start();
    } catch (err) {
      if (onerror) onerror(err);
    }
  }

  _stopPlayback() {
    if (this._sourceNode) {
      try {
        this._sourceNode.stop();
        this._sourceNode.disconnect();
      } catch (_err) {
        // already stopped
      }
      this._sourceNode = null;
    }
  }

  cancel() {
    this._stopPlayback();
    if (this._worker) {
      this._worker.postMessage({ type: "cancel" });
    }
  }
}

// ---------------------------------------------------------------------------
// Server TTS engine (Elixir /api/conversations/audio endpoint)
// ---------------------------------------------------------------------------
//
// With T0015 the "server" engine is the *audio mode*: the whole conversation
// reply (LLM + server TTS) is produced in one POST to /api/conversations/audio,
// and the returned WAV is played back through `playWav/2`. `speak/4` (which
// synthesized arbitrary text via the legacy /api/tts endpoint) is kept only to
// preserve the engine interface for the settings picker and existing fallbacks.

class ServerTTSEngine {
  constructor() {
    this._ready = false;
    this._initPromise = null;
    this._audioContext = null;
    this._sourceNode = null;
    this._controller = null;
  }

  init() {
    if (this._initPromise) return this._initPromise;
    this._initPromise = this._checkEndpoint();
    return this._initPromise;
  }

  // Verifies the endpoint is reachable without synthesizing real audio: a
  // blank text is always rejected with a 4xx validation error, which still
  // proves the route exists. Only a network-level failure is unreachable.
  async _checkEndpoint() {
    try {
      await fetch("/api/conversations/audio", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text: "" }),
      });
      this._ready = true;
      console.log("[soundai] Server TTS engine ready (/api/conversations/audio reachable)");
    } catch (err) {
      this._ready = false;
      throw new Error(`Server TTS endpoint unreachable: ${err?.message || err}`);
    }
  }

  isReady() {
    return this._ready;
  }

  // Legacy: synthesize arbitrary text server-side via /api/tts. No longer used
  // by voice_assistant.js in audio mode, kept for interface compatibility.
  speak(text, language, options = {}) {
    const { onend, onerror } = options;

    if (!this._ready) {
      if (onerror) onerror(new Error("Server TTS engine not ready"));
      return;
    }

    this._stopPlayback();

    const controller = new AbortController();
    this._controller = controller;

    fetch("/api/tts", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text }),
      signal: controller.signal,
    })
      .then(async (res) => {
        if (!res.ok) {
          const body = await res.json().catch(() => ({}));
          throw new Error(body?.error?.message || `Server TTS failed (HTTP ${res.status})`);
        }
        const audio = await res.arrayBuffer();
        if (controller.signal.aborted) return;
        this._playAudio(audio, onend, onerror);
      })
      .catch((err) => {
        if (err?.name === "AbortError") return;
        if (onerror) onerror(err);
      });
  }

  // Plays a WAV returned by /api/conversations/audio. The primary playback
  // path for audio mode; also honours cancel() via _stopPlayback.
  playWav(arrayBuffer, options = {}) {
    const { onend, onerror } = options;
    this._stopPlayback();
    this._playAudio(arrayBuffer, onend, onerror);
  }

  async _playAudio(arrayBuffer, onend, onerror) {
    try {
      if (!this._audioContext || this._audioContext.state === "closed") {
        this._audioContext = new (window.AudioContext || window.webkitAudioContext)();
      }
      const ctx = this._audioContext;
      if (ctx.state === "suspended") {
        await ctx.resume();
      }

      const buffer = await ctx.decodeAudioData(arrayBuffer);

      const source = ctx.createBufferSource();
      source.buffer = buffer;
      source.connect(ctx.destination);
      this._sourceNode = source;

      source.onended = () => {
        this._sourceNode = null;
        if (onend) onend();
      };

      source.onerror = () => {
        this._sourceNode = null;
        if (onerror) onerror(new Error("Audio playback failed"));
      };

      source.start();
    } catch (err) {
      if (onerror) onerror(new Error(`Failed to play server WAV: ${err?.message || err}`));
    }
  }

  _stopPlayback() {
    if (this._controller) {
      try {
        this._controller.abort();
      } catch (_err) {
        // already aborted
      }
      this._controller = null;
    }
    if (this._sourceNode) {
      try {
        this._sourceNode.stop();
        this._sourceNode.disconnect();
      } catch (_err) {
        // already stopped
      }
      this._sourceNode = null;
    }
  }

  cancel() {
    this._stopPlayback();
  }
}

// ---------------------------------------------------------------------------
// Language mapping (shared between native engine and voice_assistant.js)
// ---------------------------------------------------------------------------

function languageToBCP47(lang) {
  const map = {
    spanish: "es-ES",
    english: "en-US",
    french: "fr-FR",
    german: "de-DE",
    italian: "it-IT",
    portuguese: "pt-BR",
    japanese: "ja-JP",
    korean: "ko-KR",
    chinese: "zh-CN",
  };
  return map[lang] || lang;
}

// ---------------------------------------------------------------------------
// Engine registry
// ---------------------------------------------------------------------------

const _engines = {
  native: NativeTTSEngine,
  server: ServerTTSEngine,
};

/**
 * Create a TTS engine instance by id.
 *
 * Known ids: "native" (speechSynthesis), "server" (server audio replies via
 * /api/conversations/audio), plus one per local Transformers.js model in
 * TTS_CONFIG.
 * Unknown ids fall back to the native engine with a console warning.
 */
export function createTTSEngine(engineId) {
  const Ctor = _engines[engineId];
  if (Ctor) {
    return new Ctor();
  }

  console.warn(
    `[soundai] TTS engine "${engineId}" is not implemented; falling back to native engine`
  );
  return new NativeTTSEngine();
}

/**
 * Register a new TTS engine class.
 * The class must implement the engine interface (init, isReady, speak, cancel).
 */
export function registerTTSEngine(id, Ctor) {
  _engines[id] = Ctor;
}

// Register each local TTS model id from TTS_CONFIG. Runs after the registry
// (_engines) is defined so registerTTSEngine can reach it.
for (const model of TTS_CONFIG.models) {
  registerTTSEngine(model.id, class extends TransformersTTSEngine {
    constructor() {
      super(model.id);
    }
  });
}