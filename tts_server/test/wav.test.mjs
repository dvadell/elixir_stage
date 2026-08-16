// T0002 WAV encoder unit tests: header layout, PCM16 conversion, clamping.
import { test } from "node:test";
import assert from "node:assert/strict";
import { encodeWav } from "../src/wav.mjs";

function header(buf) {
  const v = new DataView(buf);
  const str = (o, n) => Buffer.from(buf).toString("ascii", o, o + n);
  return {
    riff: str(0, 4),
    riffSize: v.getUint32(4, true),
    wave: str(8, 4),
    fmt: str(12, 4),
    fmtSize: v.getUint32(16, true),
    format: v.getUint16(20, true),
    channels: v.getUint16(22, true),
    sampleRate: v.getUint32(24, true),
    byteRate: v.getUint32(28, true),
    blockAlign: v.getUint16(32, true),
    bits: v.getUint16(34, true),
    data: str(36, 4),
    dataSize: v.getUint32(40, true),
  };
}

function pcm(buf, i) {
  return new DataView(buf).getInt16(44 + i * 2, true);
}

test("encodeWav: 44-byte header with correct fields", () => {
  const buf = encodeWav(new Float32Array(100), 16000);
  assert.equal(buf.byteLength, 44 + 100 * 2);
  const h = header(buf);
  assert.equal(h.riff, "RIFF");
  assert.equal(h.riffSize, 36 + 100 * 2);
  assert.equal(h.wave, "WAVE");
  assert.equal(h.fmt, "fmt ");
  assert.equal(h.fmtSize, 16);
  assert.equal(h.format, 1); // PCM
  assert.equal(h.channels, 1); // mono
  assert.equal(h.sampleRate, 16000);
  assert.equal(h.byteRate, 32000);
  assert.equal(h.blockAlign, 2);
  assert.equal(h.bits, 16);
  assert.equal(h.data, "data");
  assert.equal(h.dataSize, 100 * 2);
});

test("encodeWav: PCM16 conversion with exact full-scale mapping", () => {
  const buf = encodeWav(new Float32Array([0, 0.5, -0.5, 1, -1, 0.25]), 16000);
  assert.deepEqual(
    [0, 1, 2, 3, 4, 5].map((i) => pcm(buf, i)),
    [0, 16384, -16384, 32767, -32768, 8192],
  );
});

test("encodeWav: out-of-range input clamps, NaN becomes silence", () => {
  const buf = encodeWav(new Float32Array([2, -2, NaN, undefined]), 8000);
  assert.deepEqual(
    [0, 1, 2, 3].map((i) => pcm(buf, i)),
    [32767, -32768, 0, 0],
  );
  const h = header(buf);
  assert.equal(h.sampleRate, 8000);
  assert.equal(h.byteRate, 16000);
});

test("encodeWav: empty input produces a valid zero-sample WAV", () => {
  const buf = encodeWav(new Float32Array(0), 16000);
  assert.equal(buf.byteLength, 44);
  const h = header(buf);
  assert.equal(h.dataSize, 0);
  assert.equal(h.riffSize, 36);
});