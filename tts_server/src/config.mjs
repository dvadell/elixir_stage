// Configuration for the TTS server.
//
// Every setting comes from an environment variable with a sane default
// (TECHNICAL_NOTES.md §5). loadConfig() fails fast (throws) on invalid
// numeric values so misconfiguration surfaces at boot, not on first
// request.
//
// Export:
//   loadConfig(env = process.env) -> Config
//
// Config fields:
//   host: string             HOST                   default "0.0.0.0"
//   port: number             PORT                   default 8080
//   model: string            TTS_MODEL              default "Xenova/mms-tts-spa"
//   dtype: string            TTS_DTYPE              default "q8" (q8 | fp32)
//   defaultLanguage: string  TTS_DEFAULT_LANGUAGE   default "spanish"
//   maxTextLength: number    TTS_MAX_TEXT_LENGTH    default 1000
//   maxQueue: number         TTS_MAX_QUEUE          default 8
//   synthTimeoutMs: number   TTS_SYNTH_TIMEOUT_MS   default 30000
//   shutdownTimeoutMs: number TTS_SHUTDOWN_TIMEOUT_MS default 20000
//   cacheDir: string|null    TTS_CACHE_DIR          default null (transformers default)

function strEnv(env, name, def) {
  const raw = env[name];
  if (raw === undefined || raw.trim() === "") return def;
  return raw.trim();
}

function intEnv(env, name, def, { min = 1 } = {}) {
  const raw = env[name];
  if (raw === undefined || raw.trim() === "") return def;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < min) {
    throw new Error(`invalid ${name}=${JSON.stringify(raw)}: expected an integer >= ${min}`);
  }
  return value;
}

export function loadConfig(env = process.env) {
  const dtype = strEnv(env, "TTS_DTYPE", "q8");
  if (dtype !== "q8" && dtype !== "fp32") {
    throw new Error(
      `invalid TTS_DTYPE=${JSON.stringify(dtype)}: expected "q8" or "fp32"`,
    );
  }

  return {
    host: strEnv(env, "HOST", "0.0.0.0"),
    port: intEnv(env, "PORT", 8080, { min: 0 }),
    model: strEnv(env, "TTS_MODEL", "Xenova/mms-tts-spa"),
    dtype,
    defaultLanguage: strEnv(env, "TTS_DEFAULT_LANGUAGE", "spanish"),
    maxTextLength: intEnv(env, "TTS_MAX_TEXT_LENGTH", 1000, { min: 1 }),
    maxQueue: intEnv(env, "TTS_MAX_QUEUE", 8, { min: 1 }),
    synthTimeoutMs: intEnv(env, "TTS_SYNTH_TIMEOUT_MS", 30000, { min: 1 }),
    shutdownTimeoutMs: intEnv(env, "TTS_SHUTDOWN_TIMEOUT_MS", 20000, { min: 1 }),
    cacheDir: strEnv(env, "TTS_CACHE_DIR", null),
  };
}