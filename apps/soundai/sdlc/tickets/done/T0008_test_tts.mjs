import { pipeline, env } from "@huggingface/transformers";

env.allowLocalModels = false;
env.useBrowserCache = false;
env.useWasmCache = false;
env.logLevel = "warning";

const spanishText = "Buenos días. Hoy hace un día hermoso y soleado. ¿Qué planes tienes para el fin de semana?";

// Supertonic voice embeddings URL
const SPEAKER_EMBEDDINGS = "https://huggingface.co/onnx-community/Supertonic-TTS-2-ONNX/resolve/main/voices/M1.bin";

async function testModel(modelId, label, options = {}) {
  console.log(`\n=== ${label} ===`);
  console.log(`Model: ${modelId}`);
  
  try {
    const t0 = performance.now();
    const synthesizer = await pipeline("text-to-speech", modelId);
    const loadTime = performance.now() - t0;
    console.log(`Cold load time: ${loadTime.toFixed(0)}ms`);
    
    // Synthesis
    const s0 = performance.now();
    const output = await synthesizer(spanishText, options);
    const synthTime = performance.now() - s0;
    
    console.log(`Primed synthesis time: ${synthTime.toFixed(0)}ms`);
    console.log(`Output type: ${typeof output}`);
    console.log(`Output keys: ${JSON.stringify(Object.keys(output))}`);
    
    if (output.audio) {
      const audioDuration = (output.audio.length / output.sampling_rate) * 1000;
      const ratio = audioDuration / synthTime;
      console.log(`Audio samples: ${output.audio.length}`);
      console.log(`Sampling rate: ${output.sampling_rate}`);
      console.log(`Audio duration: ${audioDuration.toFixed(0)}ms`);
      console.log(`Synthesis ratio: ${ratio.toFixed(2)}x`);
      console.log(`Result: SUCCESS`);
      return { success: true, loadTime, synthTime, audioDuration, ratio, samplingRate: output.sampling_rate };
    } else {
      console.log(`Result: FAILED - no audio in output`);
      console.log(`Output:`, JSON.stringify(output, null, 2).substring(0, 500));
      return { success: false, error: "no audio" };
    }
  } catch (err) {
    console.log(`Result: FAILED - ${err.message}`);
    return { success: false, error: err.message };
  }
}

// Test MMS (baseline)
const mmsResult = await testModel("Xenova/mms-tts-spa", "MMS TTS (baseline)");

// Test Supertonic with speaker embeddings
const supertonicResult = await testModel(
  "onnx-community/Supertonic-TTS-2-ONNX",
  "Supertonic-TTS-2-ONNX (with speaker embeddings)",
  { speaker_embeddings: SPEAKER_EMBEDDINGS }
);

console.log("\n=== SUMMARY ===");
console.log("MMS:", mmsResult.success ? `OK (load ${mmsResult.loadTime.toFixed(0)}ms, synth ${mmsResult.synthTime.toFixed(0)}ms, ratio ${mmsResult.ratio.toFixed(2)}x)` : `FAILED: ${mmsResult.error}`);
console.log("Supertonic:", supertonicResult.success ? `OK (load ${supertonicResult.loadTime.toFixed(0)}ms, synth ${supertonicResult.synthTime.toFixed(0)}ms, ratio ${supertonicResult.ratio.toFixed(2)}x)` : `FAILED: ${supertonicResult.error}`);
