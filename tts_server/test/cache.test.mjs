// T0003c tests: model-cache persistence (warm-cache verification).
//
// A cold start with a fresh TTS_CACHE_DIR downloads the model (~38 MB q8) and
// logs each file; a warm start with the same directory reads from disk — no
// download logs, a "model loaded from cache" log, and a faster load. The app
// detects the cache-hit up front (transformers.js replays identical progress
// events on cache hits, so the events themselves cannot tell the difference).
// The cache layout is transformers.js's own; we only assert that files landed
// in the configured directory and that both loads end with a usable pipeline.
//
// Network is required: the cold start pulls the model from the Hugging Face
// CDN, exactly as a first pod start would.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const fixturePath = fileURLToPath(new URL("./fixtures/cache_fixture.mjs", import.meta.url));

function tick(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function startFixture(cacheDir) {
  const child = spawn(process.execPath, [fixturePath], {
    env: { ...process.env, PORT: "0", TTS_CACHE_DIR: cacheDir },
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (d) => (stdout += d.toString()));
  child.stderr.on("data", (d) => (stderr += d.toString()));
  return { child, stdout: () => stdout, stderr: () => stderr };
}

function waitForText(fx, predicate, { timeoutMs, label }) {
  const deadline = Date.now() + timeoutMs;
  return (async () => {
    while (Date.now() < deadline) {
      if (predicate(fx.stdout())) return;
      await tick(50);
    }
    throw new Error(`timed out waiting for ${label}; got:\n${fx.stdout()}\n${fx.stderr()}`);
  })();
}

test("TTS_CACHE_DIR: cold start downloads the model, warm start does not", async () => {
  const cacheDir = mkdtempSync(join(tmpdir(), "tts-cache-"));
  try {
    // Cold start: empty cache dir -> download logs, files land in the dir.
    // Wait for SYNTH_OK, not MODEL_READY: the fixture prints MODEL_READY then
    // runs one synthesis, and the download/load assertions below read the
    // fully-collected stdout.
    const cold = startFixture(cacheDir);
    await waitForText(cold, (l) => /SYNTH_OK/.test(l), {
      timeoutMs: 180_000, // first start: ~38 MB download + load + synthesis
      label: "cold start ready and usable",
    });
    assert.match(cold.stdout(), /^CACHE_DIR .*tts-cache-/m, "TTS_CACHE_DIR is honored");
    assert.match(
      cold.stdout(),
      /"msg":"model download started"/,
      "cold start downloads the model",
    );
    assert.match(cold.stdout(), /"msg":"model file cached"/, "downloaded files are cached");
    assert.match(cold.stdout(), /SYNTH_OK/, "cached model is usable end-to-end");
    const coldMs = Number(cold.stdout().match(/MODEL_READY (\d+)/)[1]);
    assert.ok(readdirSync(cacheDir).length > 0, "model files land in TTS_CACHE_DIR");
    cold.child.kill();

    // Warm start: same dir -> no download, faster load, still usable.
    const warm = startFixture(cacheDir);
    await waitForText(warm, (l) => /SYNTH_OK/.test(l), {
      timeoutMs: 60_000,
      label: "warm start ready and usable",
    });
    assert.doesNotMatch(
      warm.stdout(),
      /"msg":"model download started"/,
      "warm start does not re-download the model",
    );
    assert.doesNotMatch(
      warm.stdout(),
      /"msg":"model file cached"/,
      "nothing re-downloaded on warm start",
    );
    assert.match(
      warm.stdout(),
      /"msg":"model loaded from cache"/,
      "warm start reads the model from the cache",
    );
    assert.match(warm.stdout(), /SYNTH_OK/, "warm-cached model is usable");
    const warmMs = Number(warm.stdout().match(/MODEL_READY (\d+)/)[1]);
    assert.ok(warmMs < coldMs, `warm load (${warmMs}ms) faster than cold (${coldMs}ms)`);
    warm.child.kill();
  } finally {
    rmSync(cacheDir, { recursive: true, force: true });
  }
});