// Serialized FIFO synthesis queue (contents land in T0003).
//
// Exports:
//   class Queue
//   class QueueError extends Error   (code: "queue_full" | "synth_timeout")
//
//   new Queue({ max, log })
//     max: queue bound (TTS_MAX_QUEUE)
//     log: (level, msg, fields) structured logger (src/log.mjs)
//
//   q.enqueue(job) -> Promise
//     job: { run: () => Promise, timeoutMs: number }
//     Runs jobs strictly one at a time, FIFO. Rejects with QueueError
//     "queue_full" when saturated (HTTP 429 busy) and "synth_timeout" when a
//     job exceeds timeoutMs (HTTP 500 synthesis_failed).
//
//   q.pending() -> number
//     Jobs waiting (not counting the one in flight).
//
//   q.drain() -> Promise
//     Resolves when in-flight + queued jobs finish. Used by graceful
//     shutdown (T0003).
//
// T0001 skeleton: the model is not ready, so no jobs are ever enqueued.

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

  constructor({ max, log }) {
    this.#max = max;
    this.#log = log;
  }

  enqueue(_job) {
    throw new QueueError("not_implemented", "Queue.enqueue lands in T0003");
  }

  pending() {
    return 0;
  }

  drain() {
    return Promise.resolve();
  }

  get max() {
    return this.#max;
  }
}