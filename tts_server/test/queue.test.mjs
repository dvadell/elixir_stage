// T0003a queue unit tests: serialized FIFO, bounded saturation, timeouts, and
// failure isolation.
import { test } from "node:test";
import assert from "node:assert/strict";
import { Queue, QueueError } from "../src/queue.mjs";

const noopLog = () => {};

function makeQueue(max = 8, logger = noopLog) {
  return new Queue({ max, log: logger });
}

test("enqueue runs jobs one at a time in FIFO order", async () => {
  const q = makeQueue(8);
  const order = [];
  const run = (name, ms) => () =>
    new Promise((resolve) =>
      setTimeout(() => {
        order.push(name);
        resolve(name);
      }, ms),
    );
  const results = await Promise.all([
    q.enqueue({ run: run("a", 30), timeoutMs: 1000 }),
    q.enqueue({ run: run("b", 5), timeoutMs: 1000 }),
    q.enqueue({ run: run("c", 1), timeoutMs: 1000 }),
  ]);
  // FIFO even though b/c are faster: serialized, not concurrent.
  assert.deepEqual(order, ["a", "b", "c"]);
  assert.deepEqual(results, ["a", "b", "c"]);
});

test("pending() counts jobs waiting, not the one in flight", async () => {
  const q = makeQueue(8);
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  const inFlight = q.enqueue({ run: () => gate, timeoutMs: 1000 });
  const waiting = q.enqueue({ run: async () => "ok", timeoutMs: 1000 });
  assert.equal(q.pending(), 1);
  release();
  await inFlight;
  await waiting;
  assert.equal(q.pending(), 0);
});

test("enqueue rejects with queue_full when saturated", async () => {
  const q = makeQueue(2);
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  const inFlight = q.enqueue({ run: () => gate, timeoutMs: 1000 }).catch(() => {});
  const queued = q.enqueue({ run: async () => "b", timeoutMs: 1000 }).catch(() => {});
  assert.equal(q.pending(), 1);
  const fits = q.enqueue({ run: async () => "c", timeoutMs: 1000 }).catch(() => {});
  assert.equal(q.pending(), 2);
  assert.throws(
    () => q.enqueue({ run: async () => "d", timeoutMs: 1000 }),
    (err) => {
      assert.ok(err instanceof QueueError);
      assert.equal(err.code, "queue_full");
      return true;
    },
  );
  release();
  await Promise.all([inFlight, queued, fits]);
});

test("a job that exceeds its timeout rejects with synth_timeout and the queue continues", async () => {
  const q = makeQueue(8);
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  const stalled = q.enqueue({ run: () => gate, timeoutMs: 20, requestId: "stuck" });
  const next = q.enqueue({ run: async () => "ok", timeoutMs: 1000 });
  await assert.rejects(
    stalled,
    (err) => err instanceof QueueError && err.code === "synth_timeout",
  );
  assert.equal(await next, "ok");
  release(); // abandon the gated run; its resolution is ignored (already settled)
  await q.drain();
});

test("a failing job is isolated: later jobs still run", async () => {
  const q = makeQueue(8);
  const failing = q.enqueue({
    run: async () => {
      throw new Error("boom");
    },
    timeoutMs: 1000,
  });
  const after = q.enqueue({ run: async () => "fine", timeoutMs: 1000 });
  await assert.rejects(failing, /boom/);
  assert.equal(await after, "fine");
});

test("jobs without a timeout are never timed out", async () => {
  const q = makeQueue(8);
  assert.equal(await q.enqueue({ run: async () => "no-timeout" }), "no-timeout");
});

test("drain resolves once in-flight and queued jobs finish", async () => {
  const q = makeQueue(8);
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  const running = q.enqueue({ run: () => gate, timeoutMs: 1000 });
  const queued = q.enqueue({ run: async () => "q", timeoutMs: 1000 });
  const drained = q.drain();
  let resolved = false;
  drained.then(() => {
    resolved = true;
  });
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(resolved, false, "drain waits for queued work");
  release();
  await running;
  await queued;
  await drained;
  assert.equal(q.pending(), 0);
});

test("drain on an idle queue resolves immediately", async () => {
  const q = makeQueue(8);
  await q.drain();
  assert.equal(q.pending(), 0);
});

test("timeout log line carries requestId and synth duration", async () => {
  const lines = [];
  const logger = (level, msg, fields = {}) => lines.push({ level, msg, ...fields });
  const q = makeQueue(8, logger);
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  const stalled = q.enqueue({ run: () => gate, timeoutMs: 10, requestId: "r-123" }).catch(() => {});
  await stalled;
  release();
  const timeoutLog = lines.find((l) => l.msg === "synthesis timed out");
  assert.ok(timeoutLog, "timeout is logged");
  assert.equal(timeoutLog.level, "warn");
  assert.equal(timeoutLog.requestId, "r-123");
  assert.equal(typeof timeoutLog.synthMs, "number");
  assert.equal(timeoutLog.synthMs >= 10, true);
});

// --- T0003b: shutdown + drain ---

test("shutdown() rejects new enqueues with shutting_down", async () => {
  const q = makeQueue(8);
  q.shutdown();
  assert.throws(
    () => q.enqueue({ run: async () => "nope", timeoutMs: 1000 }),
    (err) => {
      assert.ok(err instanceof QueueError);
      assert.equal(err.code, "shutting_down");
      return true;
    },
  );
});

test("shutdown() does not block in-flight or queued jobs from draining", async () => {
  const q = makeQueue(8);
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  const inFlight = q.enqueue({ run: () => gate, timeoutMs: 1000 });
  const queued = q.enqueue({ run: async () => "queued", timeoutMs: 1000 });
  const drained = q.drain();
  q.shutdown();
  assert.throws(
    () => q.enqueue({ run: async () => "late", timeoutMs: 1000 }),
    (err) => err instanceof QueueError && err.code === "shutting_down",
  );
  release();
  assert.equal(await inFlight, undefined);
  assert.equal(await queued, "queued");
  await drained;
  assert.equal(q.pending(), 0);
});

test("stats() reports queued and in-flight counts", async () => {
  const q = makeQueue(8);
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  const inFlight = q.enqueue({ run: () => gate, timeoutMs: 1000 });
  const queued = q.enqueue({ run: async () => "q", timeoutMs: 1000 });
  assert.deepEqual(q.stats(), { queued: 1, inFlight: 1 });
  release();
  await Promise.all([inFlight, queued]);
  assert.deepEqual(q.stats(), { queued: 0, inFlight: 0 });
});

test("drain completes a timed-out queued job and still resolves", async () => {
  const q = makeQueue(8);
  const stalled = q.enqueue({
    run: () => new Promise(() => {}),
    timeoutMs: 15,
    requestId: "stuck-1",
  }).catch(() => {});
  const next = q.enqueue({ run: async () => "ok", timeoutMs: 1000 });
  const drained = q.drain();
  await stalled;
  assert.equal(await next, "ok");
  await drained;
  assert.equal(q.pending(), 0);
});