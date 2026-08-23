----
title: Epic — Code review remediation (csr-errors triage)
----

Triage of the automated code review output in `csr-errors` (repo root):
~90 findings across server, web, frontend JS, deps, and tests, organized into
the tickets below. Every finding is either mapped to a ticket or explicitly
recorded as deferred/won't-fix in this file.

Status: **open** — all tickets T0019…T0038 pending unless noted.

## Ticket map

| # | Title | Area | Priority |
|---|-------|------|----------|
| T0019 | Spike — AuthN/AuthZ & rate limiting for the public voice API | Server/Infra | P0 |
| T0020 | Security hardening quick wins (salt, RequestLogger, cookies, key redaction) | Server | P0 |
| T0021 | TTS pipeline robustness (timeouts, failure caching, normalization) | Server | P1 |
| T0022 | WAV encoder correctness (shape guards, quantization) | Server | P1 |
| T0023 | Honest model & language reporting in the TTS API | Server | P2 |
| T0024 | SpeechText correctness (thousands separators, emoji ranges) | Server | P1 |
| T0025 | LLM seam & API-edge error normalization | Server | P1 |
| T0026 | Conversation lifecycle semantics (reset race, advance-on-failure) | Server | P2 |
| T0027 | HTTPClient defaults & weather tool hardening | Server | P1 |
| T0028 | Supervision & runtime-config lifecycle | Server | P2 |
| T0029 | Whisper worker fallback race & language default | Client JS | P1 |
| T0030 | Browser TTS engine readiness & races | Client JS | P2 |
| T0031 | Client bootstrap & settings hardening | Client JS | P2 |
| T0032 | Vendor topbar.js defensive patches | Client JS | P3 |
| T0033 | Theme system consistency & CSS hygiene | Web UI | P2 |
| T0034 | Layout & core component fixes | Web UI | P2 |
| T0035 | npm lockfile repair & gettext POT header | Deps | P1 |
| T0036 | Test suite isolation (env leaks, async:false contracts) | Tests | P1 |
| T0037 | TTS tests decoupled from runtime state | Tests | P2 |
| T0038 | Assertion strength & coverage pass | Tests | P3 |

## Triaging decisions

- **Spikes over big features**: authentication/authorization/rate limiting is
  a design problem before it is code — part of the auth story already lives
  in the SSL terminator outside this repo. T0019 captures the inventory,
  design, and follow-up ticket creation instead of jumping to an
  implementation.
- **Quick security wins split from the spike** (T0020): hardcoded signing
  salt, prod RequestLogger, cookie Secure flags, and API-key redaction in the
  smoke task are concrete, low-risk, and shouldn't wait on the design work.
- **Grouping**: findings were clustered by module and root cause (e.g. all
  `OrtexServer`/`Soundai.TTS` contract violations in T0021) so each ticket
  has one reviewable diff and its own test plan.
- **Severity adjustments after verification**: findings were checked against
  the code before ticketing. Notable confirmations: `GenServer.call(...,
  :infinity)` (`ortex_server.ex:31`), decimal-comma regex
  (`speech_text.ex:44`), lockfile resolving `onnxruntime-web@1.27.0` against
  a prerelease range, client-controlled `conversation_id` param precedence
  (`transcription_controller.ex:76`), hardcoded signing salt
  (`endpoint.ex:10`).

## Deferred / won't-fix register

- `sdlc/tickets/done/T0008_supertonic_test.html` and
  `sdlc/tickets/done/T0008_test_tts.mjs` findings (AudioContext leak,
  missing exit codes/timeouts, silent SUCCESS states): these are **archived
  one-off benchmark artifacts** under `done/`, not run by CI or the app. No
  tickets created; apply the listed fixes only if the scripts are ever
  revived for a new model bake-off.
- Confirm-only observations (documented inside their tickets, no behavior
  change planned): worker PCM interleaved-mono assumption and cancel
  semantics (T0030); topbar `destroy()` (T0032, optional).
- Optional performance ideas kept non-blocking: weather geocode TTL cache and
  generic HTTP verb wrapper (both marked optional in T0027).

## Suggested execution order

1. T0020 (immediate), then run the T0019 spike in parallel with P1 batch.
2. P1 batch: T0021, T0022, T0024, T0025, T0027, T0035, T0036, T0029.
3. P2/P3 batch: T0023, T0026, T0028, T0030–T0034, T0037, T0038.
4. Implementation tickets spun out of T0019 slot here once designed.

## Verification (epic level)

```sh
cd apps/soundai && mix test && mix precommit   # umbrella root
mix assets.build                                # after client-side tickets
```

Manual browser matrices defined per ticket (STT/TTS flows remain
browser-verified per TECH_DESCRIPTION §10). Each ticket carries its own
acceptance criteria and Done section; close them individually.
