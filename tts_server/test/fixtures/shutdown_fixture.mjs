// Subprocess fixture for T0003b graceful-shutdown tests. Started by
// shutdown.test.mjs, which reads its stdout markers and sends real signals.
//
// Markers on stdout:
//   LISTENING <port>          server bound
//   SYNTH_START <requestId>   a synthesis began (in-flight)
//   SYNTH_END <requestId>     a synthesis finished
//   DRAINED <json>            drain summary (from the "drain complete" log)
//
// Env:
//   PORT                      0 (random) or explicit
//   SYNTH_MS                   synthesis duration (default 200)
//   TTS_SHUTDOWN_TIMEOUT_MS   drain deadline (default 20000)
import { createServer, buildShutdownHandler } from "../../src/server.mjs";
import { loadConfig } from "../../src/config.mjs";
import { Queue } from "../../src/queue.mjs";
import { log } from "../../src/log.mjs";

const SYNTH_MS = Number(process.env.SYNTH_MS ?? 200);

class FakeTTS {
  modelId = "Xenova/mms-tts-spa";
  async start() {}
  isReady() {
    return true;
  }
  supportedLanguages() {
    return ["spanish"];
  }
  async synthesize(_text, _language, requestId = null) {
    console.log(`SYNTH_START ${requestId ?? ""}`);
    await new Promise((resolve) => setTimeout(resolve, SYNTH_MS));
    console.log(`SYNTH_END ${requestId ?? ""}`);
    const n = 16000;
    const audio = new Float32Array(n);
    for (let i = 0; i < n; i++) audio[i] = Math.sin((2 * Math.PI * 440 * i) / n);
    return { audio, samplingRate: 16000 };
  }
}

const cfg = loadConfig(process.env);
const tts = new FakeTTS();
const queue = new Queue({ max: cfg.maxQueue, log });
const server = createServer(cfg, tts, queue);

const shutdown = buildShutdownHandler({ server, queue, cfg, log });
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

server.listen(cfg.port, cfg.host, () => {
  console.log(`LISTENING ${server.address().port}`);
});