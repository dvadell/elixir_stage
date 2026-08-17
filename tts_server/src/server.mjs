// HTTP entry point (node:http, no framework).
//
// Routes (PRD.md §7):
//   GET  /healthz  -> 200 {"status":"ok"}                      liveness, process up
//   GET  /readyz   -> 200 {"status":"ready"} | 503 {"status":"starting"}
//   POST /v1/tts   -> 200 audio/wav | 400/413/422/503/500 JSON error
//   other          -> 404 {"error":{"code":"not_found",...}}
//
// POST /v1/tts flow (T0002 + T0003a):
//   parse JSON (else 400 bad_request)
//   -> validate text/language (422 missing_text | empty_text | text_too_long |
//      unsupported_language)
//   -> readiness check (503 not_ready while the model is loading)
//   -> queue.enqueue (serialized FIFO, bounded): 429 busy on saturation,
//      500 synthesis_failed on timeout or synthesis failure
//   -> tts.synthesize (one at a time, per-request timeout)
//   -> wav.encode -> 200 audio/wav + X-TTS-Model, X-TTS-Duration-Ms
//
// Error bodies are always JSON: {"error":{"code":...,"message":...}}.
//
// Startup: config fails fast on invalid envs (src/config.mjs). The server binds
// immediately; readiness gates traffic on model load, liveness never does.
// The model is loaded once via tts.start() (T0002).
//
// Shutdown (T0003b): SIGTERM/SIGINT flip a flag, stop accepting new
// connections, reject any request sneaking in on a keep-alive connection
// (503 shutting_down), drain in-flight + queued synthesis, then exit 0. A
// hard deadline TTS_SHUTDOWN_TIMEOUT_MS force-exits 1 if the drain overruns.
// K8s terminationGracePeriodSeconds (T0004) must exceed the drain budget.

import http from "node:http";
import { randomUUID } from "node:crypto";
import { pathToFileURL } from "node:url";
import { loadConfig } from "./config.mjs";
import { log } from "./log.mjs";
import { TTS } from "./tts.mjs";
import { Queue, QueueError } from "./queue.mjs";
import { encodeWav } from "./wav.mjs";

const MAX_BODY_BYTES = 64 * 1024;

function sendJson(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

function sendError(res, status, code, message) {
  sendJson(res, status, { error: { code, message } });
}

function sendWav(res, buffer, { model, durationMs }) {
  res.writeHead(200, {
    "Content-Type": "audio/wav",
    "Content-Length": buffer.byteLength,
    "X-TTS-Model": model,
    "X-TTS-Duration-Ms": String(Math.round(durationMs)),
  });
  res.end(Buffer.from(buffer));
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let aborted = false;
    req.on("data", (chunk) => {
      if (aborted) return;
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        aborted = true;
        // Drain the rest of the body without buffering so the connection can
        // be reused and our 4xx response is actually delivered (destroying the
        // socket here would kill the response mid-flight).
        req.resume();
        const err = new Error("body too large");
        err.code = "PAYLOAD_TOO_LARGE";
        reject(err);
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

// PRD.md §7.1 validation. Returns { text, language } or an [status, code,
// message] error triple. Order: text presence, then blankness, then length,
// then language.
function validateTtsBody(body, cfg, supportedLanguages) {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return [422, "missing_text", "request body must be a JSON object with a \"text\" field"];
  }
  const { text } = body;
  if (text === undefined || text === null) {
    return [422, "missing_text", "\"text\" is required"];
  }
  if (typeof text !== "string") {
    return [422, "missing_text", "\"text\" must be a string"];
  }
  const trimmed = text.trim();
  if (trimmed.length === 0) {
    return [422, "empty_text", "\"text\" is blank after trimming"];
  }
  if (trimmed.length > cfg.maxTextLength) {
    return [422, "text_too_long", `\"text\" exceeds ${cfg.maxTextLength} characters`];
  }
  const language =
    body.language === undefined || body.language === null
      ? cfg.defaultLanguage
      : typeof body.language === "string"
        ? body.language.trim()
        : null;
  if (language === null) {
    return [422, "unsupported_language", "\"language\" must be a string"];
  }
  if (language.length === 0) {
    return [422, "unsupported_language", "\"language\" must not be blank"];
  }
  if (!supportedLanguages.includes(language)) {
    return [
      422,
      "unsupported_language",
      `unsupported language "${language}"; supported: ${supportedLanguages.join(", ")}`,
    ];
  }
  return { text: trimmed, language };
}

export function createServer(cfg, tts, queue, logger = log) {
  return http.createServer(async (req, res) => {
    const url = new URL(req.url, "http://localhost");
    try {
      if (req.method === "GET" && url.pathname === "/healthz") {
        sendJson(res, 200, { status: "ok" });
      } else if (req.method === "GET" && url.pathname === "/readyz") {
        const ready = tts.isReady();
        sendJson(res, ready ? 200 : 503, { status: ready ? "ready" : "starting" });
      } else if (req.method === "POST" && url.pathname === "/v1/tts") {
        let raw;
        try {
          raw = await readBody(req);
        } catch (err) {
          if (err?.code === "PAYLOAD_TOO_LARGE") {
            sendError(
              res,
              413,
              "payload_too_large",
              `request body exceeds ${MAX_BODY_BYTES} bytes`,
            );
          } else {
            sendError(res, 400, "bad_request", "request body could not be read");
          }
          return;
        }

        let body;
        try {
          body = JSON.parse(raw);
        } catch {
          sendError(res, 400, "bad_request", "request body is not valid JSON");
          return;
        }

        const validated = validateTtsBody(body, cfg, tts.supportedLanguages());
        if (Array.isArray(validated)) {
          const [status, code, message] = validated;
          sendError(res, status, code, message);
          return;
        }
        const { text, language } = validated;

        if (!tts.isReady()) {
          sendError(res, 503, "not_ready", "model is still loading");
          return;
        }

        // Serialized synthesis goes through the queue (T0003a): one synthesis
        // in flight, FIFO, bounded. A full queue returns 429 busy promptly
        // (no waiting behind an unbounded backlog), and the per-request
        // timeout turns a hung inference into 500 synthesis_failed without
        // stalling the next request.
        const requestId = randomUUID();
        const enqueuedAt = Date.now();
        let queueWaitMs = null;
        let synthMs = null;
        const job = {
          requestId,
          timeoutMs: cfg.synthTimeoutMs,
          run: () => {
            queueWaitMs = Date.now() - enqueuedAt;
            const synthStart = Date.now();
            return tts.synthesize(text, language, requestId).then((result) => {
              synthMs = Date.now() - synthStart;
              return result;
            });
          },
        };

        let result;
        try {
          result = await queue.enqueue(job);
        } catch (err) {
          if (err instanceof QueueError && err.code === "shutting_down") {
            logger("warn", "request refused; server shutting down", { requestId });
            sendError(res, 503, "shutting_down", "server is shutting down");
            return;
          }
          if (err instanceof QueueError && err.code === "queue_full") {
            logger("warn", "queue full -> 429", { requestId });
            sendError(res, 429, "busy", "synthesis queue is full; retry later");
            return;
          }
          if (err instanceof QueueError && err.code === "synth_timeout") {
            // The queue already logged "synthesis timed out" with the request
            // id and synth duration.
            sendError(res, 500, "synthesis_failed", "speech synthesis timed out");
            return;
          }
          logger("error", "tts request failed", {
            code: "synthesis_failed",
            kind: err?.kind ?? "unknown",
            model: tts.modelId,
            requestId,
            textLen: text.length,
            language,
            queueWaitMs,
            msg: err?.message,
          });
          sendError(res, 500, "synthesis_failed", "speech synthesis failed");
          return;
        }

        const wav = encodeWav(result.audio, result.samplingRate);
        const durationMs = (result.audio.length / result.samplingRate) * 1000;
        logger("info", "tts request ok", {
          model: tts.modelId,
          language,
          textLen: text.length,
          requestId,
          queueWaitMs,
          synthMs,
          bytes: wav.byteLength,
          durationMs: Math.round(durationMs),
        });
        sendWav(res, wav, { model: tts.modelId, durationMs });
      } else {
        sendError(res, 404, "not_found", `no route for ${req.method} ${url.pathname}`);
      }
    } catch (err) {
      logger("error", "unhandled request error", { msg: err?.message });
      if (!res.headersSent) sendError(res, 500, "synthesis_failed", "internal error");
    }
  });
}

// Builds the graceful-shutdown handler (T0003b). Returns an async function
// (signal) => void. `exit` is injectable so tests can assert on the exit code
// without killing the test runner (defaults to process.exit).
//
// Flow (TECHNICAL_NOTES.md §5):
//   SIGTERM -> stop accepting -> queue.shutdown() -> drain (in-flight +
//   queued) + wait for connections to flush -> exit 0, or force-exit 1 after
//   TTS_SHUTDOWN_TIMEOUT_MS. Waiting for the server 'close' event (instead of
//   exiting the instant drain resolves) guarantees the final response is
//   written before exit.
export function buildShutdownHandler({ server, queue, cfg, log, exit = process.exit }) {
  let shuttingDown = false;
  return async (signal) => {
    if (shuttingDown) return;
    shuttingDown = true;
    const startedAt = Date.now();
    const { queued, inFlight } = queue.stats();
    log("info", "shutting down; stop accepting new connections", { signal, queued, inFlight });
    queue.shutdown();

    // A signal may race server.listen() (e.g. at boot); close() throws when
    // not listening, so guard on server.listening.
    const serverClosed = server.listening
      ? new Promise((resolve) => {
          server.once("close", resolve);
          server.close();
        })
      : Promise.resolve();

    const forced = await Promise.race([
      Promise.all([queue.drain(), serverClosed]).then(() => false),
      new Promise((resolve) =>
        // unref(): never keep the process alive past the grace period just to
        // run the kill switch.
        setTimeout(() => resolve(true), cfg.shutdownTimeoutMs).unref(),
      ),
    ]);

    const drainMs = Date.now() - startedAt;
    if (forced) {
      log("error", "shutdown timed out; forcing exit", { signal, drainMs });
      exit(1);
      return;
    }
    log("info", "drain complete", { signal, queued, inFlight, drainMs });
    exit(0);
  };
}

export function main() {
  let cfg;
  try {
    cfg = loadConfig();
  } catch (err) {
    log("error", "invalid configuration", { msg: err.message });
    process.exit(1);
  }

  const tts = new TTS(cfg, log);
  const queue = new Queue({ max: cfg.maxQueue, log });
  const server = createServer(cfg, tts, queue);

  const shutdown = buildShutdownHandler({ server, queue, cfg, log });
  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));

  server.on("error", (err) => {
    log("error", "server failed to start", { msg: err.message });
    process.exit(1);
  });

  server.listen(cfg.port, cfg.host, () => {
    log("info", "tts server listening", {
      host: cfg.host,
      port: cfg.port,
      model: cfg.model,
      dtype: cfg.dtype,
      maxQueue: cfg.maxQueue,
    });
  });

  // Load the model once at startup (T0002). Readiness gates /v1/tts on it;
  // liveness (/healthz) never does (TECHNICAL_NOTES.md §9): a failed download
  // keeps the process up (no crash-loop) while /readyz and /v1/tts report
  // 503 until the model is usable. On failure (e.g. a transient network error
  // mid-download) retry with exponential backoff so the pod self-heals
  // instead of sitting at 503 forever.
  loadWithRetry(tts, cfg);
}

const RETRY_DELAYS_MS = [1_000, 5_000, 15_000, 30_000];

async function loadWithRetry(tts, cfg, attempt = 0) {
  try {
    await tts.start();
    // tts.start() logs "[tts] model ready" with loadMs on success.
  } catch {
    const delay = RETRY_DELAYS_MS[attempt] ?? RETRY_DELAYS_MS[RETRY_DELAYS_MS.length - 1];
    log("error", "model load failed; scheduling retry", {
      model: cfg.model,
      attempt: attempt + 1,
      nextRetryMs: delay,
    });
    // unref(): never block shutdown on a pending retry.
    setTimeout(() => loadWithRetry(tts, cfg, attempt + 1), delay).unref();
  }
}

// Run main() only when invoked directly (node src/server.mjs), not when a test
// imports this module.
const isDirectRun = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isDirectRun) main();