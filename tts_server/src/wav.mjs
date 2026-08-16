// WAV encoder (contents land in T0002).
//
// Export:
//   encodeWav(samples: Float32Array, sampleRate: number) -> ArrayBuffer
//
// Encodes the standard 44-byte-header 16-bit PCM little-endian mono WAV
// (TECHNICAL_NOTES.md §4) so any browser can decode it with
// AudioContext.decodeAudioData. No external dependency.

export function encodeWav(_samples, _sampleRate) {
  throw new Error("encodeWav not implemented yet (T0002)");
}