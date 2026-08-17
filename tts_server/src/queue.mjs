// Serialized FIFO synthesis queue (T0003a + T0003b).
//
// Exports:
//   class Queue
//   class QueueError extends Error   (code: "queue_full" | "synth_timeout" | "shutting_down")
//
//   new Queue({ max, log })
//     max: queue bound (TTS_MAX_QUEUE); jobs beyond it are rejected
//     log: (level, msg, fields) structured logger (src/log.mjs)
//
//   q.enqueue(job) -> Promise
//     job: { run: () => Promise, timeoutMs: number, requestId: string }
//     Runs jobs strictly one at a time, FIFO (onnxruntime-web is
//     single-threaded per session; TECHNICAL_NOTES.md §3). Rejects with
//     QueueError "queue_full" when saturated (HTTP 429 busy), "synth_timeout"
//     when a job exceeds timeoutMs (HTTP 500 synthesis_failed), and
//     "shutting_down" once q.shutdown() has been called. A timed-out or failed
//     job never blocks the next one in line.
//
//   q.shutdown()
//     Flips the queue into shutting-down mode: subsequent enqueue calls are
//     rejected with "shutting_down" (the server has already stopped accepting,
//     so this only guards in-flight keep-alive connections). In-flight and
//     queued jobs still complete.
//
//   q.pending() -> number
//     Jobs waiting (not counting the one in flight).
//
//   q.stats() -> { queued, inFlight }
//     Snapshot for the shutdown drain summary.
//
//   q.drain() -> Promise
//     Resolves when in-flight + queued jobs finish. Used by graceful
//     shutdown (T0003b). A timed-out or abandoned job is logged and the
//     drain continues with the next item.
//
// Future: worker_threads pool (documented only — T0003c, not implemented).
// To lift the concurrency ceiling above 1, replace the single shared pipeline
// with a pool of `worker_threads`: one worker per CPU, N =
// os.availableParallelism() (Node's `hardwareConcurrency`), each worker
// loading its own copy of the model and its own pipeline. This queue becomes
// a scheduler that dispatches jobs to the workers round-robin (or to the
// first idle one), keeping the existing FIFO + timeout + drain semantics.
// Memory grows ~linearly with N (one model copy per worker), so start at
// N = 1 and only raise it when expected concurrency exceeds 1 (TECHNICAL_NOTES
// §3). Per-request timing still applies inside each worker.

export class QueueError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "QueueError";
    this.code = code;
  }
}

export class Queue {
  #max;
  #log;
  #waiting = [];
  #running = false;
  #shuttingDown = false;
  #drainWaiters = [];

  constructor({ max, log }) {
    this.#max = max;
    this.#log = log;
  }

  enqueue(job) {
    if (this.#shuttingDown) {
      throw new QueueError("shutting_down", "queue is shutting down");
    }
    if (this.#waiting.length >= this.#max) {
      throw new QueueError("queue_full", `queue is full (max ${this.#max})`);
    }
    return new Promise((resolve, reject) => {
      this.#waiting.push({ job, resolve, reject });
      this.#pump();
    });
  }

  shutdown() {
    this.#shuttingDown = true;
  }

  pending() {
    return this.#waiting.length;
  }

  stats() {
    return { queued: this.#waiting.length, inFlight: this.#running ? 1 : 0 };
  }

  drain() {
    if (!this.#running && this.#waiting.length === 0) return Promise.resolve();
    return new Promise((resolve) => this.#drainWaiters.push(resolve));
  }

  // Dequeue and run the next job, one at a time. The per-job timer bounds a
  // hung inference so it can never hang the queue or other clients.
  #pump() {
    if (this.#running || this.#waiting.length === 0) return;
    this.#running = true;
    const { job, resolve, reject } = this.#waiting.shift();
    const { run, timeoutMs = null, requestId = null } = job;

    let settled = false;
    let timer = null;
    const startedAt = Date.now();
    const finish = (ok, value) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      this.#running = false;
      if (ok) resolve(value);
      else reject(value);
      this.#pump();
      this.#settleDrainWaiters();
    };

    if (timeoutMs !== null && timeoutMs > 0) {
      timer = setTimeout(() => {
        this.#log("warn", "synthesis timed out", {
          requestId,
          timeoutMs,
          synthMs: Date.now() - startedAt,
        });
        finish(false, new QueueError("synth_timeout", `synthesis exceeded ${timeoutMs} ms`));
      }, timeoutMs);
    }

    Promise.resolve()
      .then(() => run())
      .then((value) => finish(true, value))
      .catch((err) => finish(false, err));
  }

  #settleDrainWaiters() {
    if (this.#running || this.#waiting.length > 0 || this.#drainWaiters.length === 0) return;
    const waiters = this.#drainWaiters.splice(0, this.#drainWaiters.length);
    for (const resolve of waiters) resolve();
  }

  get max() {
    return this.#max;
  }
}
