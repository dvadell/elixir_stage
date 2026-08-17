// Structured JSON-line logger (TECHNICAL_NOTES.md §5).
//
// Line shape: { level, msg, ...fields } — synthesis requests carry
// { requestId, queueWaitMs, synthMs, encodeMs, bytes, model }.
// error/warn go to stderr, everything else to stdout.
//
// Writes are synchronous (fs.writeSync) so logs survive process.exit(): the
// shutdown path logs "drain complete" / "shutdown timed out" immediately
// before exiting (T0003b), and process.exit() drops buffered async writes.
import { writeSync } from "node:fs";

export function log(level, msg, fields = {}) {
  const line = JSON.stringify({ level, msg, ...fields });
  const fd = level === "error" || level === "warn" ? 2 : 1;
  writeSync(fd, line + "\n");
}