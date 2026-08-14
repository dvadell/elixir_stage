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
};

/**
 * Create a TTS engine instance by id.
 *
 * Known ids: "native" (speechSynthesis).
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