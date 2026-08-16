// Structured JSON-line logger (TECHNICAL_NOTES.md §5).
//
// Line shape: { level, msg, ...fields } — synthesis requests carry
// { requestId, queueWaitMs, synthMs, encodeMs, bytes, model }.
// error/warn go to stderr, everything else to stdout.
export function log(level, msg, fields = {}) {
  const line = JSON.stringify({ level, msg, ...fields });
  const out = level === "error" || level === "warn" ? process.stderr : process.stdout;
  out.write(line + "\n");
}