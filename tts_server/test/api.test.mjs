// T0002 API tests: health endpoints, /v1/tts (validation, synthesis, WAV),
// config fail-fast.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "../src/server.mjs";
import { loadConfig } from "../src/config.mjs";
import { TTSError } from "../src/tts.mjs";

const cfg = loadConfig({ PORT: "0" });
// Stub TTS: model not loaded (readiness false); speaks only the MVP language.
class StubTTS {
  #ready = false;
  modelId = "Xenova/mms-tts-spa";
  async start() {}
  isReady() {
    return this.#ready;
  }
  supportedLanguages() {
    return ["spanish"];
  }
}
const stubQueue = { max: 8, pending: () => 0, drain: () => Promise.resolve() };

// Ready TTS fake: model loaded; synthesizes a deterministic 1-second 440 Hz
// sine at the model's 16 kHz sampling rate (drives X-TTS-Duration-Ms = 1000).
class ReadyTTS {
  modelId = "Xenova/mms-tts-spa";
  async start() {}
  isReady() {
    return true;
  }
  supportedLanguages() {
    return ["spanish"];
  }
  async synthesize(_text, _language) {
    const n = 16000;
    const audio = new Float32Array(n);
    for (let i = 0; i < n; i++) audio[i] = Math.sin((2 * Math.PI * 440 * i) / n);
    return { audio, samplingRate: 16000 };
  }
}

// Failing TTS fake: ready, but synthesis throws a typed inference error.
class FailingTTS extends ReadyTTS {
  async synthesize() {
    throw new TTSError("inference", "boom");
  }
}

function startServer(srv) {
  return new Promise((resolve) =>
    srv.listen(0, "127.0.0.1", () => resolve(`http://127.0.0.1:${srv.address().port}`)),
  );
}

let server;
let base;

before(async () => {
  server = createServer(cfg, new StubTTS(), stubQueue);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => new Promise((resolve) => server.close(resolve)));

test("GET /healthz -> 200 {status: ok}", async () => {
  const res = await fetch(`${base}/healthz`);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("content-type"), "application/json; charset=utf-8");
  assert.deepEqual(await res.json(), { status: "ok" });
});

test("GET /readyz -> 503 {status: starting} until model ready", async () => {
  const res = await fetch(`${base}/readyz`);
  assert.equal(res.status, 503);
  assert.deepEqual(await res.json(), { status: "starting" });
});

test("GET /readyz -> 200 {status: ready} once model is ready", async () => {
  const srv = createServer(cfg, new ReadyTTS(), stubQueue);
  const url = await startServer(srv);
  try {
    const res = await fetch(`${url}/readyz`);
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { status: "ready" });
  } finally {
    await new Promise((resolve) => srv.close(resolve));
  }
});

test("POST /v1/tts malformed JSON -> 400 bad_request", async () => {
  const res = await fetch(`${base}/v1/tts`, {
    method: "POST",
    body: "{not json",
    headers: { "Content-Type": "application/json" },
  });
  assert.equal(res.status, 400);
  const body = await res.json();
  assert.equal(body.error.code, "bad_request");
});

test("POST /v1/tts valid JSON -> 503 not_ready (stub)", async () => {
  const res = await fetch(`${base}/v1/tts`, {
    method: "POST",
    body: JSON.stringify({ text: "Buenos días", language: "spanish" }),
    headers: { "Content-Type": "application/json" },
  });
  assert.equal(res.status, 503);
  const body = await res.json();
  assert.equal(body.error.code, "not_ready");
});

test("POST /v1/tts missing text -> 422 missing_text", async () => {
  const res = await fetch(`${base}/v1/tts`, {
    method: "POST",
    body: JSON.stringify({ language: "spanish" }),
  });
  assert.equal(res.status, 422);
  assert.equal((await res.json()).error.code, "missing_text");
});

test("POST /v1/tts blank text -> 422 empty_text", async () => {
  const res = await fetch(`${base}/v1/tts`, {
    method: "POST",
    body: JSON.stringify({ text: "  \t " }),
  });
  assert.equal(res.status, 422);
  assert.equal((await res.json()).error.code, "empty_text");
});

test("POST /v1/tts non-string text -> 422 missing_text", async () => {
  const res = await fetch(`${base}/v1/tts`, {
    method: "POST",
    body: JSON.stringify({ text: 42 }),
  });
  assert.equal(res.status, 422);
  assert.equal((await res.json()).error.code, "missing_text");
});

test("POST /v1/tts text too long -> 422 text_too_long", async () => {
  const res = await fetch(`${base}/v1/tts`, {
    method: "POST",
    body: JSON.stringify({ text: "a".repeat(cfg.maxTextLength + 1) }),
  });
  assert.equal(res.status, 422);
  assert.equal((await res.json()).error.code, "text_too_long");
});

test("POST /v1/tts unsupported language -> 422 unsupported_language", async () => {
  const res = await fetch(`${base}/v1/tts`, {
    method: "POST",
    body: JSON.stringify({ text: "Hola", language: "klingon" }),
  });
  assert.equal(res.status, 422);
  assert.equal((await res.json()).error.code, "unsupported_language");
});

test("POST /v1/tts language is trimmed before validation", async () => {
  const srv = createServer(cfg, new ReadyTTS(), stubQueue);
  const url = await startServer(srv);
  try {
    const res = await fetch(`${url}/v1/tts`, {
      method: "POST",
      body: JSON.stringify({ text: "Hola", language: "  spanish " }),
    });
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "audio/wav");
  } finally {
    await new Promise((resolve) => srv.close(resolve));
  }
});

test("POST /v1/tts blank language -> 422 unsupported_language", async () => {
  const res = await fetch(`${base}/v1/tts`, {
    method: "POST",
    body: JSON.stringify({ text: "Hola", language: "   " }),
  });
  assert.equal(res.status, 422);
  assert.equal((await res.json()).error.code, "unsupported_language");
});

test("POST /v1/tts body over size limit -> 413 payload_too_large", async () => {
  const res = await fetch(`${base}/v1/tts`, {
    method: "POST",
    body: JSON.stringify({ text: "a".repeat(128 * 1024) }),
  });
  assert.equal(res.status, 413);
  assert.equal((await res.json()).error.code, "payload_too_large");
});

test("POST /v1/tts ready -> 200 audio/wav (headers + PCM data)", async () => {
  const srv = createServer(cfg, new ReadyTTS(), stubQueue);
  const url = await startServer(srv);
  try {
    const res = await fetch(`${url}/v1/tts`, {
      method: "POST",
      body: JSON.stringify({ text: "Buenos días" }),
    });
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "audio/wav");
    assert.equal(res.headers.get("x-tts-model"), "Xenova/mms-tts-spa");
    assert.equal(res.headers.get("x-tts-duration-ms"), "1000");
    const buf = Buffer.from(await res.arrayBuffer());
    assert.equal(buf.byteLength, 44 + 16000 * 2);
    assert.equal(res.headers.get("content-length"), String(buf.byteLength));
    assert.equal(buf.toString("ascii", 0, 4), "RIFF");
    assert.equal(buf.toString("ascii", 8, 12), "WAVE");
    assert.equal(buf.toString("ascii", 36, 40), "data");
    const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
    assert.equal(view.getUint16(22, true), 1); // mono
    assert.equal(view.getUint32(24, true), 16000); // sampling rate
    assert.equal(view.getUint16(34, true), 16); // PCM 16-bit
    assert.equal(view.getUint32(40, true), 16000 * 2); // data chunk size
    assert.equal(view.getInt16(44, true), 0); // first sample: sin(0)
  } finally {
    await new Promise((resolve) => srv.close(resolve));
  }
});

test("POST /v1/tts synthesis failure -> 500 synthesis_failed", async () => {
  const srv = createServer(cfg, new FailingTTS(), stubQueue);
  const url = await startServer(srv);
  try {
    const res = await fetch(`${url}/v1/tts`, {
      method: "POST",
      body: JSON.stringify({ text: "Buenos días" }),
    });
    assert.equal(res.status, 500);
    assert.equal((await res.json()).error.code, "synthesis_failed");
  } finally {
    await new Promise((resolve) => srv.close(resolve));
  }
});

test("unknown route -> 404 not_found", async () => {
  const res = await fetch(`${base}/nope`);
  assert.equal(res.status, 404);
  const body = await res.json();
  assert.equal(body.error.code, "not_found");
});

test("config: defaults", () => {
  const c = loadConfig({});
  assert.equal(c.host, "0.0.0.0");
  assert.equal(c.port, 8080);
  assert.equal(c.model, "Xenova/mms-tts-spa");
  assert.equal(c.defaultLanguage, "spanish");
  assert.equal(c.maxTextLength, 1000);
  assert.equal(c.maxQueue, 8);
  assert.equal(c.synthTimeoutMs, 30000);
  assert.equal(c.cacheDir, null);
});

test("config: invalid numeric env fails fast", () => {
  assert.throws(() => loadConfig({ PORT: "abc" }), /PORT/);
  assert.throws(() => loadConfig({ TTS_MAX_QUEUE: "0" }), /TTS_MAX_QUEUE/);
  assert.throws(() => loadConfig({ TTS_SYNTH_TIMEOUT_MS: "-5" }), /TTS_SYNTH_TIMEOUT_MS/);
  assert.throws(() => loadConfig({ TTS_MAX_TEXT_LENGTH: "1.5" }), /TTS_MAX_TEXT_LENGTH/);
});

test("config: env overrides", () => {
  const c = loadConfig({ PORT: "9090", TTS_MODEL: "other/model", TTS_CACHE_DIR: "/cache" });
  assert.equal(c.port, 9090);
  assert.equal(c.model, "other/model");
  assert.equal(c.cacheDir, "/cache");
});
