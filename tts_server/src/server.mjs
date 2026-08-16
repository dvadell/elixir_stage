// HTTP entry point (T0001: node:http, no framework).
//
// Routes (PRD.md §7):
//   GET  /healthz  -> 200 {"status":"ok"}                      liveness, process up
//   GET  /readyz   -> 200 {"status":"ready"} | 503 {"status":"starting"}
//   POST /v1/tts   -> 503 not_ready (stub; T0002 wires the model)
//   other          -> 404 {"error":{"code":"not_found",...}}
//
// Error bodies are always JSON: {"error":{"code":...,"message":...}}.
//
// Startup: config fails fast on invalid envs (src/config.mjs). The server binds
// immediately; readiness gates traffic on model load, liveness never does.
// The model is loaded once via tts.start() (T0002).
//
// Shutdown: SIGTERM/SIGINT stop accepting new connections and exit (full
// in-flight drain lands in T0003).

import http from "node:http";
import { pathToFileURL } from "node:url";
import { loadConfig } from "./config.mjs";
import { log } from "./log.mjs";
import { TTS } from "./tts.mjs";
import { Queue } from "./queue.mjs";

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
        reject(new Error("body too large"));
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

// Routes are dispatched by (method, path). cfg/tts/queue are the full set of
// components T0002/T0003 need; in T0001 only tts drives the responses.
export function createServer(cfg, tts, queue) {
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
        } catch {
          sendError(res, 400, "bad_request", "request body could not be read");
          return;
        }
        // T0001 validates JSON parseability only (400), then returns 503
        // not_ready. T0002 adds field validation (422) + queued synthesis.
        try {
          JSON.parse(raw);
        } catch {
          sendError(res, 400, "bad_request", "request body is not valid JSON");
          return;
        }
        if (!tts.isReady()) {
          sendError(res, 503, "not_ready", "model is still loading");
          return;
        }
        sendError(res, 500, "synthesis_failed", "synthesis not implemented yet (T0002)");
      } else {
        sendError(res, 404, "not_found", `no route for ${req.method} ${url.pathname}`);
      }
    } catch (err) {
      log("error", "unhandled request error", { msg: err?.message });
      if (!res.headersSent) sendError(res, 500, "synthesis_failed", "internal error");
    }
  });
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

  let shuttingDown = false;
  const shutdown = (signal) => {
    if (shuttingDown) return;
    shuttingDown = true;
    log("info", "shutting down; stop accepting new connections", { signal });
    server.close(() => process.exit(0));
    // K8s kill switch if the close overruns the grace period.
    setTimeout(() => process.exit(1), 10_000).unref();
  };
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
      maxQueue: cfg.maxQueue,
    });
  });

  // Load the model once (T0002). The process stays up regardless (liveness is
  // independent of the model); /readyz keeps gating traffic until ready.
  tts
    .start()
    .then(() => {
      if (tts.isReady()) log("info", "model ready", { model: cfg.model });
    })
    .catch((err) => log("error", "model load failed", { model: cfg.model, msg: err.message }));
}

// Run main() only when invoked directly (node src/server.mjs), not when a test
// imports this module.
const isDirectRun = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isDirectRun) main();