// T0002 + T0003a API tests: health endpoints, /v1/tts (validation, synthesis,
// WAV), serialized queue (saturation 429, timeout 500, isolation), config
// fail-fast.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "../src/server.mjs";
import { loadConfig } from "../src/config.mjs";
import { TTSError } from "../src/tts.mjs";
import { Queue } from "../src/queue.mjs";

const cfg = loadConfig({ PORT: "0" });

function makeQueue(max = cfg.maxQueue, logger = () => {}) {
  return new Queue({ max, log: logger });
}

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
  server = createServer(cfg, new StubTTS(), makeQueue());
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
  const srv = createServer(cfg, new ReadyTTS(), makeQueue());
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
  const srv = createServer(cfg, new ReadyTTS(), makeQueue());
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
  const srv = createServer(cfg, new ReadyTTS(), makeQueue());
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
  const srv = createServer(cfg, new FailingTTS(), makeQueue());
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

// --- T0003a: serialized FIFO queue, saturation 429, timeouts, isolation ---

// Captures structured log lines so tests can assert on queue behavior
// (serialization, requestId, saturation/timeout markers).
function captureLog() {
  const lines = [];
  const logger = (level, msg, fields = {}) => lines.push({ level, msg, ...fields });
  return { lines, logger };
}

// Tracks concurrent synthesis calls to prove the queue serializes.
class TrackingTTS extends ReadyTTS {
  #inFlight = 0;
  maxInFlight = 0;
  async synthesize(text, language) {
    this.#inFlight++;
    this.maxInFlight = Math.max(this.maxInFlight, this.#inFlight);
    await new Promise((resolve) => setTimeout(resolve, 20));
    const result = await super.synthesize(text, language);
    this.#inFlight--;
    return result;
  }
}

// Gated TTS: first synthesis blocks until release() is called.
function gatedTTS() {
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  class GatedTTS extends ReadyTTS {
    async synthesize() {
      await gate;
      return super.synthesize();
    }
  }
  return { release, TTS: GatedTTS };
}

// Stalls only the first synthesis (never resolves); later calls work.
class FirstCallStallsTTS extends ReadyTTS {
  #stalled = false;
  async synthesize(text, language) {
    if (!this.#stalled) {
      this.#stalled = true;
      return new Promise(() => {});
    }
    return super.synthesize(text, language);
  }
}

// Fails only the first synthesis; later calls work.
class FlakyTTS extends ReadyTTS {
  #failed = false;
  async synthesize(text, language) {
    if (!this.#failed) {
      this.#failed = true;
      throw new TTSError("inference", "boom");
    }
    return super.synthesize(text, language);
  }
}

test("POST /v1/tts concurrent requests serialize through the queue", async () => {
  const { lines, logger } = captureLog();
  const tts = new TrackingTTS();
  const srv = createServer(cfg, tts, makeQueue(cfg.maxQueue, logger), logger);
  const url = await startServer(srv);
  try {
    const responses = await Promise.all(
      Array.from({ length: 5 }, () =>
        fetch(`${url}/v1/tts`, { method: "POST", body: JSON.stringify({ text: "Hola" }) }),
      ),
    );
    for (const res of responses) {
      assert.equal(res.status, 200);
      assert.equal(res.headers.get("content-type"), "audio/wav");
      const buf = Buffer.from(await res.arrayBuffer());
      assert.equal(buf.toString("ascii", 0, 4), "RIFF");
      assert.equal(buf.toString("ascii", 36, 40), "data");
    }
    // Never two syntheses at once on the shared pipeline.
    assert.equal(tts.maxInFlight, 1);
    // Every success carries a requestId + latency breakdown.
    const okLogs = lines.filter((l) => l.msg === "tts request ok");
    assert.equal(okLogs.length, 5);
    for (const l of okLogs) {
      assert.ok(l.requestId, "success log has requestId");
      assert.equal(typeof l.synthMs, "number");
      assert.equal(typeof l.queueWaitMs, "number");
    }
    assert.equal(new Set(okLogs.map((l) => l.requestId)).size, 5);
  } finally {
    await new Promise((resolve) => srv.close(resolve));
  }
});

test("POST /v1/tts saturated queue -> 429 busy (JSON error)", async () => {
  const { lines, logger } = captureLog();
  const { release, TTS: GatedTTS } = gatedTTS();
  const srv = createServer(cfg, new GatedTTS(), makeQueue(1, logger), logger);
  const url = await startServer(srv);
  try {
    const pending = Array.from({ length: 3 }, () =>
      fetch(`${url}/v1/tts`, { method: "POST", body: JSON.stringify({ text: "Hola" }) }),
    );
    // First request is in flight, second queued, third rejected: the 429
    // surfaces while the gated requests are still pending. Race for it so we
    // don't wait behind the gate.
    const busy = await Promise.race(
      pending.map((p) => p.then((res) => (res.status === 429 ? res : null))),
    );
    assert.ok(busy, "a request was rejected while the queue was saturated");
    assert.equal((await busy.json()).error.code, "busy");
    assert.ok(lines.some((l) => l.msg === "queue full -> 429"), "logs saturation");
    release();
    const results = await Promise.all(pending);
    assert.deepEqual(results.map((r) => r.status).sort(), [200, 200, 429]);
    for (const res of results) {
      if (res.status === 200) {
        assert.equal(res.headers.get("content-type"), "audio/wav");
        const buf = Buffer.from(await res.arrayBuffer());
        assert.equal(buf.toString("ascii", 0, 4), "RIFF");
      }
    }
  } finally {
    release();
    await new Promise((resolve) => srv.close(resolve));
  }
});

test("POST /v1/tts stalled synthesis -> 500 after timeout; next request succeeds", async () => {
  const { lines, logger } = captureLog();
  const shortTimeoutCfg = loadConfig({ PORT: "0", TTS_SYNTH_TIMEOUT_MS: "50" });
  const srv = createServer(shortTimeoutCfg, new FirstCallStallsTTS(), makeQueue(8, logger), logger);
  const url = await startServer(srv);
  try {
    const first = await fetch(`${url}/v1/tts`, {
      method: "POST",
      body: JSON.stringify({ text: "Hola" }),
    });
    assert.equal(first.status, 500);
    assert.equal((await first.json()).error.code, "synthesis_failed");
    assert.ok(lines.some((l) => l.msg === "synthesis timed out"), "logs timeout");
    const second = await fetch(`${url}/v1/tts`, {
      method: "POST",
      body: JSON.stringify({ text: "Hola" }),
    });
    assert.equal(second.status, 200);
    assert.equal(second.headers.get("content-type"), "audio/wav");
  } finally {
    await new Promise((resolve) => srv.close(resolve));
  }
});

test("POST /v1/tts failing synthesis is isolated; next request succeeds", async () => {
  const srv = createServer(cfg, new FlakyTTS(), makeQueue());
  const url = await startServer(srv);
  try {
    const first = await fetch(`${url}/v1/tts`, {
      method: "POST",
      body: JSON.stringify({ text: "Hola" }),
    });
    assert.equal(first.status, 500);
    assert.equal((await first.json()).error.code, "synthesis_failed");
    const second = await fetch(`${url}/v1/tts`, {
      method: "POST",
      body: JSON.stringify({ text: "Hola" }),
    });
    assert.equal(second.status, 200);
    assert.equal(second.headers.get("content-type"), "audio/wav");
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
