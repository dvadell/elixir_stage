// T0001 API tests: health endpoints, stub /v1/tts, config fail-fast.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "../src/server.mjs";
import { loadConfig } from "../src/config.mjs";

const cfg = loadConfig({ PORT: "0" });
// Stub TTS: model not loaded (T0001 readiness is false).
class StubTTS {
  #ready = false;
  async start() {}
  isReady() {
    return this.#ready;
  }
}
const stubQueue = { max: 8, pending: () => 0, drain: () => Promise.resolve() };

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
  class ReadyTTS {
    async start() {}
    isReady() {
      return true;
    }
  }
  const srv = createServer(cfg, new ReadyTTS(), stubQueue);
  await new Promise((resolve) => srv.listen(0, "127.0.0.1", resolve));
  try {
    const res = await fetch(`http://127.0.0.1:${srv.address().port}/readyz`);
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
