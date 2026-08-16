// WAV encoder (T0002).
//
// Export:
//   encodeWav(samples: Float32Array, sampleRate: number) -> ArrayBuffer
//
// Encodes the standard 44-byte-header 16-bit PCM little-endian mono WAV
// (TECHNICAL_NOTES.md §4) so any browser can decode it with
// AudioContext.decodeAudioData with no client-side parsing. Pure function,
// no external dependency.
//
// Layout:
//   RIFF chunk | fmt chunk (PCM, 1 ch, sampleRate, 16 bit) | data chunk (PCM16)

export function encodeWav(samples, sampleRate) {
  const n = samples.length;
  const buffer = new ArrayBuffer(44 + n * 2);
  const view = new DataView(buffer);

  writeAscii(view, 0, "RIFF");
  view.setUint32(4, 36 + n * 2, true); // RIFF chunk size
  writeAscii(view, 8, "WAVE");

  writeAscii(view, 12, "fmt ");
  view.setUint32(16, 16, true); // fmt chunk size (fixed for PCM)
  view.setUint16(20, 1, true); // audio format: 1 = PCM
  view.setUint16(22, 1, true); // channels: mono
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true); // byte rate
  view.setUint16(32, 2, true); // block align
  view.setUint16(34, 16, true); // bits per sample

  writeAscii(view, 36, "data");
  view.setUint32(40, n * 2, true);

  for (let i = 0; i < n; i++) {
    // NaN/undefined clamp to silence; out-of-range clamps to full scale.
    // `|| 0` is deliberate: NaN and 0 both become 0 here.
    const s = Math.max(-1, Math.min(1, samples[i] || 0));
    // Map [-1, 1] onto [INT16_MIN, INT16_MAX] (32768 negative steps, 32767
    // positive steps) so the encoding is exact at both full-scale extremes.
    view.setInt16(44 + i * 2, s < 0 ? Math.round(s * 0x8000) : Math.round(s * 0x7fff), true);
  }
  return buffer;
}

function writeAscii(view, offset, str) {
  for (let i = 0; i < str.length; i++) {
    view.setUint8(offset + i, str.charCodeAt(i));
  }
}
