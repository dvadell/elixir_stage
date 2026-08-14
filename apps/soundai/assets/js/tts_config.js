// TTS model configuration.
//
// Single source of truth for local Transformers.js TTS models. The settings
// page options in SettingsHTML (@tts_models) must be kept in sync with the
// model ids listed here.
//
// Model options (local, browser-side):
//   Xenova/mms-tts-spa  — VITS, 16 kHz, ~38 MB quantized.
//                          Good Spanish quality for a ~36M-param model;
//                          light enough for the target users' devices.
//
// TTS is far less quantization-sensitive than Whisper's encoder, so fully
// quantized models (q8 on WASM, fp16 on WebGPU) are acceptable here.
export const TTS_CONFIG = {
  // Default engine id used when no ?tts= param or soundai_tts cookie is set.
  engine: "Xenova/mms-tts-spa",

  // Ordered list of local Transformers.js TTS model options.
  models: [
    {
      id: "Xenova/mms-tts-spa",
      dtype: {
        webgpu: {
          model: "fp16",
        },
        wasm: {
          model: "q8",
        },
      },
    },
  ],

  // Resolve the model config by id. Returns the model entry or the first
  // entry as a fallback for unknown ids (so unimplemented models still
  // attempt to load something reasonable).
  getModelConfig(modelId) {
    return this.models.find((m) => m.id === modelId) || this.models[0];
  },
};
