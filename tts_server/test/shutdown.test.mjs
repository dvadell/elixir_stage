// T0003b tests: graceful shutdown (drain in-flight + queued work, refuse new
// requests, exit 0) and the force-exit path (TTS_SHUTDOWN_TIMEOUT_MS).
//
// Two layers:
//   - in-process: buildShutdownHandler with an injected exit() so we can
//     assert on exit codes and the drain summary without killing the runner.
//   - subprocess: a real fixture process receives SIGTERM/SIGINT mid-synthesis.
import http from "node:http";
import { spawn } from "node:child_process";
import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { createServer, buildShutdownHandler } from "../src/server.mjs";
import { loadConfig } from "../src/config.mjs";
import { Queue } from "../src/queue.mjs";

const fixturePath = fileURLToPath(new URL("./fixtures/shutdown_fixture.mjs", import.meta.url));

const cfg = loadConfig({ PORT: "0", TTS_SHUTDOWN_TIMEOUT_MS: "3000" });

function tick(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// POST helper over node:http so tests control keep-alive (avoids undici's
// pooled connections lingering and blocking the runner / server close).
// Returns { promise, abort }.
function postJson(url, body, agent) {
  const controller = new AbortController();
  const promise = new Promise((resolve, reject) => {
    const req = http.request(
      url,
      { method: "POST", agent, signal: controller.signal, headers: { "Content-Type": "application/json" } },
      (res) => {
        const chunks = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () =>
          resolve({
            status: res.statusCode,
            headers: res.headers,
            text: Buffer.concat(chunks).toString("utf8"),
          }),
        );
      },
    );
    req.on("error", reject);
    req.end(JSON.stringify(body));
  });
  return { promise, abort: () => controller.abort() };
}

// A TTS whose syntheses block on a gate once `blocked` is true.
function makeGatedTTS() {
  let blocked = false;
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  class GatedTTS {
    modelId = "Xenova/mms-tts-spa";
    async start() {}
    isReady() {
      return true;
    }
    supportedLanguages() {
      return ["spanish"];
    }
    async synthesize() {
      if (blocked) await gate;
      return { audio: new Float32Array(16000), samplingRate: 16000 };
    }
  }
  return { tts: GatedTTS, setBlocked: (v) => (blocked = v), release };
}

function closeServer(srv) {
  return new Promise((resolve) => {
    if (srv.listening) srv.close(() => resolve());
    else resolve();
  });
}

test("shutdown drains in-flight + queued work, refuses new requests, exits 0", async () => {
  const lines = [];
  const logger = (level, msg, fields = {}) => lines.push({ level, msg, ...fields });
  const { tts: GatedTTS, setBlocked, release } = makeGatedTTS();
  const queue = new Queue({ max: 8, log: logger });
  const srv = createServer(cfg, new GatedTTS(), queue, logger);
  await new Promise((resolve) => srv.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${srv.address().port}`;
  // keepAlive: one socket we control; it exercises the idle-connection path
  // through shutdown (server.close() tears idle keep-alive sockets down).
  const ka = new http.Agent({ keepAlive: true, maxSockets: 1 });
  const oneShot = new http.Agent({ keepAlive: false });
  const exits = [];
  const exit = (code) => exits.push(code);
  const shutdown = buildShutdownHandler({ server: srv, queue, cfg, log: logger, exit });

  try {
    // Establish an idle keep-alive socket before shutdown begins.
    const warm = await postJson(`${base}/v1/tts`, { text: "warm" }, ka).promise;
    assert.equal(warm.status, 200);

    // Block syntheses; one in flight + one queued.
    setBlocked(true);
    const inFlight = postJson(`${base}/v1/tts`, { text: "uno" }, oneShot);
    const queued = postJson(`${base}/v1/tts`, { text: "dos" }, oneShot);
    inFlight.promise.catch(() => {});
    queued.promise.catch(() => {});
    await tick(20);
    assert.deepEqual(queue.stats(), { queued: 1, inFlight: 1 });

    // Begin shutdown (drain + connection flush pending).
    const shutting = shutdown("SIGTERM");
    await tick(20);

    // New connections are refused outright once server.close() ran: the ticket
    // allows "503 or connection refused", and fresh connections hit the
    // latter. The 503 path (a request already being received) is covered by
    // the dedicated test below.
    const refusedAgent = new http.Agent({ keepAlive: false });
    await assert.rejects(
      postJson(`${base}/v1/tts`, { text: "tres" }, refusedAgent).promise,
      { code: "ECONNREFUSED" },
      "new connections refused after shutdown begins",
    );
    refusedAgent.destroy();
    assert.equal(exits.length, 0, "exit deferred until drain finishes");
    ka.destroy(); // let the server's connections fully close

    // Release; in-flight + queued synthesis drain.
    setBlocked(false);
    release();
    const [r1, r2] = await Promise.all([inFlight.promise, queued.promise]);
    assert.equal(r1.status, 200);
    assert.equal(r2.status, 200);

    await shutting;
    assert.deepEqual(exits, [0], "exit 0 after drain");
    const summary = lines.find((l) => l.msg === "drain complete");
    assert.ok(summary, "drain summary logged");
    assert.equal(summary.queued, 1);
    assert.equal(summary.inFlight, 1);
    assert.equal(typeof summary.drainMs, "number");
  } finally {
    release?.();
    ka.destroy();
    oneShot.destroy();
    await closeServer(srv);
  }
});

test("a request being received when shutdown begins gets 503 shutting_down (no new synthesis)", async () => {
  const lines = [];
  const logger = (level, msg, fields = {}) => lines.push({ level, msg, ...fields });
  class CountingTTS {
    modelId = "Xenova/mms-tts-spa";
    calls = 0;
    async start() {}
    isReady() {
      return true;
    }
    supportedLanguages() {
      return ["spanish"];
    }
    async synthesize() {
      this.calls += 1;
      return { audio: new Float32Array(16000), samplingRate: 16000 };
    }
  }
  const tts = new CountingTTS();
  const queue = new Queue({ max: 8, log: logger });
  const srv = createServer(cfg, tts, queue, logger);
  await new Promise((resolve) => srv.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${srv.address().port}`;
  const exits = [];
  const exit = (code) => exits.push(code);
  const shutdown = buildShutdownHandler({ server: srv, queue, cfg, log: logger, exit });

  const oneShot = new http.Agent({ keepAlive: false });
  const controller = new AbortController();
  let req;
  try {
    // Send headers + a partial body so the connection is mid-request (not
    // idle) when shutdown begins; server.close() keeps active connections
    // alive, so this request reaches the handler after the queue is closed.
    const response = new Promise((resolve, reject) => {
      req = http.request(
        `${base}/v1/tts`,
        { method: "POST", agent: oneShot, signal: controller.signal, headers: { "Content-Type": "application/json" } },
        (res) => {
          const chunks = [];
          res.on("data", (chunk) => chunks.push(chunk));
          res.on("end", () =>
            resolve({ status: res.statusCode, text: Buffer.concat(chunks).toString("utf8") }),
          );
        },
      );
      req.on("error", reject);
      req.write('{"text":"hola');
    });

    await tick(20); // server is now reading the body
    const shutting = shutdown("SIGTERM");
    await tick(20); // server.close() ran; the mid-request connection survives

    req.end('"}'); // finish the body -> handler -> refused 503
    const res = await response;
    assert.equal(res.status, 503);
    assert.equal(JSON.parse(res.text).error.code, "shutting_down");
    assert.equal(tts.calls, 0, "no new synthesis started");

    await shutting;
    assert.deepEqual(exits, [0], "exit 0 after the refused request flushes");
  } finally {
    controller.abort();
    oneShot.destroy();
    await closeServer(srv);
  }
});

test("a drain exceeding TTS_SHUTDOWN_TIMEOUT_MS force-exits 1", async () => {
  const lines = [];
  const logger = (level, msg, fields = {}) => lines.push({ level, msg, ...fields });
  const fastCfg = loadConfig({ PORT: "0", TTS_SHUTDOWN_TIMEOUT_MS: "50" });
  class StalledTTS {
    modelId = "Xenova/mms-tts-spa";
    async start() {}
    isReady() {
      return true;
    }
    supportedLanguages() {
      return ["spanish"];
    }
    async synthesize() {
      return new Promise(() => {}); // never resolves
    }
  }
  const queue = new Queue({ max: 8, log: logger });
  const srv = createServer(fastCfg, new StalledTTS(), queue, logger);
  await new Promise((resolve) => srv.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${srv.address().port}`;
  const exits = [];
  const exit = (code) => exits.push(code);
  const shutdown = buildShutdownHandler({ server: srv, queue, cfg: fastCfg, log: logger, exit });

  const oneShot = new http.Agent({ keepAlive: false });
  const hung = postJson(`${base}/v1/tts`, { text: "hola" }, oneShot);
  hung.promise.catch(() => {});
  await tick(20); // let the stalled synthesis reach the queue

  try {
    await shutdown("SIGTERM");
    assert.deepEqual(exits, [1], "force-exit after the drain deadline");
    const forceLog = lines.find((l) => l.msg === "shutdown timed out; forcing exit");
    assert.ok(forceLog, "force-exit is logged");
  } finally {
    hung.abort();
    oneShot.destroy();
    await closeServer(srv);
  }
});

// --- Subprocess: real signals on the fixture ---

function startFixture(env) {
  const child = spawn(process.execPath, [fixturePath], {
    env: { ...process.env, ...env },
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (d) => (stdout += d.toString()));
  child.stderr.on("data", (d) => (stderr += d.toString()));
  return { child, stdout: () => stdout, stderr: () => stderr };
}

function waitForText(fx, predicate, { timeoutMs = 8000, label }) {
  const deadline = Date.now() + timeoutMs;
  return (async () => {
    while (Date.now() < deadline) {
      if (predicate(fx.stdout())) return;
      await tick(20);
    }
    throw new Error(`timed out waiting for ${label}; got:\n${fx.stdout()}\n${fx.stderr()}`);
  })();
}

function waitExit(child, timeoutMs = 8000) {
  return Promise.race([
    new Promise((resolve) => child.once("exit", (code, signal) => resolve({ code, signal }))),
    new Promise((resolve) => setTimeout(() => resolve({ code: null, signal: "timeout" }), timeoutMs).unref()),
  ]);
}

async function fixturePort(fx) {
  await waitForText(fx, (l) => /LISTENING \d+/.test(l), { label: "LISTENING" });
  return Number(fx.stdout().match(/LISTENING (\d+)/)[1]);
}

test("SIGTERM mid-synthesis drains in-flight + queued work and exits 0", async () => {
  const fx = startFixture({ PORT: "0", SYNTH_MS: "150", TTS_SHUTDOWN_TIMEOUT_MS: "5000" });
  const oneShot = new http.Agent({ keepAlive: false });
  try {
    const base = `http://127.0.0.1:${await fixturePort(fx)}`;
    const sent = Array.from({ length: 3 }, () => postJson(`${base}/v1/tts`, { text: "hola" }, oneShot));
    // Wait until two syntheses have started: one in flight + one queued.
    await waitForText(fx, (l) => (l.match(/SYNTH_START/g) ?? []).length >= 2, {
      label: "two syntheses started",
    });

    fx.child.kill("SIGTERM");
    const { code } = await waitExit(fx.child);
    assert.equal(code, 0, "drains and exits 0");

    const results = await Promise.all(sent.map((s) => s.promise));
    for (const res of results) {
      assert.equal(res.status, 200, "all drained requests delivered");
      assert.match(res.text.slice(0, 4), /RIFF/);
    }
    const out = fx.stdout();
    assert.equal((out.match(/"msg":"tts request ok"/g) ?? []).length, 3);
    assert.match(out, /"msg":"drain complete"/);
  } finally {
    oneShot.destroy();
    fx.child.kill("SIGKILL");
  }
});

test("SIGINT during shutdown is idempotent (single exit)", async () => {
  const fx = startFixture({ PORT: "0", SYNTH_MS: "150", TTS_SHUTDOWN_TIMEOUT_MS: "5000" });
  const oneShot = new http.Agent({ keepAlive: false });
  try {
    const base = `http://127.0.0.1:${await fixturePort(fx)}`;
    const sent = postJson(`${base}/v1/tts`, { text: "hola" }, oneShot);
    await waitForText(fx, (l) => /SYNTH_START/.test(l), { label: "synthesis started" });

    fx.child.kill("SIGTERM");
    fx.child.kill("SIGINT");
    const { code } = await waitExit(fx.child);
    assert.equal(code, 0);
    assert.equal(await sent.promise.then((r) => r.status), 200);
  } finally {
    oneShot.destroy();
    fx.child.kill("SIGKILL");
  }
});

test("a drain exceeding TTS_SHUTDOWN_TIMEOUT_MS force-exits 1 (subprocess)", async () => {
  const fx = startFixture({ PORT: "0", SYNTH_MS: "5000", TTS_SHUTDOWN_TIMEOUT_MS: "80" });
  const oneShot = new http.Agent({ keepAlive: false });
  let sent;
  try {
    const base = `http://127.0.0.1:${await fixturePort(fx)}`;
    sent = postJson(`${base}/v1/tts`, { text: "hola" }, oneShot);
    sent.promise.catch(() => {});
    await waitForText(fx, (l) => /SYNTH_START/.test(l), { label: "synthesis started" });

    fx.child.kill("SIGTERM");
    const { code } = await waitExit(fx.child);
    assert.equal(code, 1, "force-exits 1 after the drain deadline");
    assert.match(fx.stderr(), /"msg":"shutdown timed out; forcing exit"/);
  } finally {
    oneShot.destroy();
    sent.abort();
    fx.child.kill("SIGKILL");
  }
});

test("config: TTS_SHUTDOWN_TIMEOUT_MS default and override", () => {
  assert.equal(loadConfig({}).shutdownTimeoutMs, 20000);
  assert.equal(loadConfig({ TTS_SHUTDOWN_TIMEOUT_MS: "5000" }).shutdownTimeoutMs, 5000);
  assert.throws(() => loadConfig({ TTS_SHUTDOWN_TIMEOUT_MS: "0" }), /TTS_SHUTDOWN_TIMEOUT_MS/);
});