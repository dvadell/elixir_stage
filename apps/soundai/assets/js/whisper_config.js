// Whisper model configuration.
//
// Change the model/language/dtype here and restart benchmarks; no other code
// needs to change. Prefer a multilingual model so Spanish (and other
// languages) are supported.
//
// Model options (multilingual):
//   onnx-community/whisper-base   ~74M params — best balance of download,
//                                  speed and accuracy. Default.
//   onnx-community/whisper-small  ~244M params — noticeably better accuracy,
//                                  but ~2-3x slower and a bigger download.
//                                  Use on WebGPU or with the WASM thread pool.
//
// Whisper's audio encoder is very sensitive to quantization: running it as
// int8 garbles speech, especially accented/noisy audio like Spanish. dtypes
// below therefore always keep the encoder fp32 and only quantize the text
// decoder. Downloads: wasm ~130MB (fp32 encoder + q8 decoder), webgpu ~180MB
// (fp32 encoder + fp16 decoder).
export const WHISPER_CONFIG = {
  model: "onnx-community/whisper-base",
  language: "spanish",
  // Per-module quantization, per inference device.
  dtype: {
    webgpu: {
      encoder_model: "fp32",
      decoder_model_merged: "fp16",
    },
    wasm: {
      encoder_model: "fp32",
      decoder_model_merged: "q8",
    },
  },
  // Utterances shorter than this are skipped (noise taps, quick brushes).
  minUtteranceMs: 200,
};