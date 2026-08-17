// Subprocess fixture for T0003c model-cache tests. Loads the model with
// TTS_CACHE_DIR set and reports markers so cache.test.mjs can verify a cold
// start downloads the model and a warm start does not.
//
// Markers on stdout:
//   CACHE_DIR <path>            effective TTS_CACHE_DIR
//   MODEL_READY <loadMs>        model loaded (includes any download time)
//   SYNTH_OK                    one synthesis succeeded (cache fully usable)
//   MODEL_LOAD_FAILED <msg>     load error (test times out with this message)
//
// Structured logs (src/log.mjs, written synchronously) carry
// "model download started" / "model file cached" only when the model is
// actually downloaded, so their absence on a warm start is the proof that the
// cache was honored.
import { TTS } from "../../src/tts.mjs";
import { loadConfig } from "../../src/config.mjs";
import { log } from "../../src/log.mjs";

const cfg = loadConfig(process.env);
console.log(`CACHE_DIR ${cfg.cacheDir ?? "(default)"}`);

const tts = new TTS(cfg, log);
const startedAt = Date.now();
try {
  await tts.start();
} catch (err) {
  console.log(`MODEL_LOAD_FAILED ${err?.message ?? err}`);
  process.exit(1);
}
console.log(`MODEL_READY ${Date.now() - startedAt}`);

try {
  const out = await tts.synthesize("hola", "spanish");
  if (out.audio?.length > 0) console.log("SYNTH_OK");
} catch (err) {
  console.log(`SYNTH_FAILED ${err?.message ?? err}`);
  process.exit(1);
}