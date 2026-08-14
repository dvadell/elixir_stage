# Soundai

Voice-first AI assistant web app (a Phoenix umbrella app alongside `soundpanel`).
One big button: **press → speak → release**, and the assistant transcribes your
speech locally, sends the text to the server, and speaks the server's reply back
to you. Built for people who prefer talking over reading (see the PRD).

## What works

Speech is transcribed **in the browser** — raw microphone audio never leaves the
device. The transcribed text is POSTed to Phoenix, which echoes it back as
`response`, and the browser speaks *that server text* aloud using the native
Web Speech API (`speechSynthesis`). There is no LLM yet: the server returns the
same text it received.

```text
press → speak → release
    → Whisper (WebGPU / WASM) transcribes locally
    → POST /api/transcriptions {text, language}
    → {"ok": true, "response": "...", "language": "..."}
    → speechSynthesis speaks the server's response
```

- **Offline-first**: once the page shell and the Whisper model are cached, STT
  keeps working with no network. The transcript send is best-effort and fails
  quietly (transcript stays visible).
- **No LiveView / websocket**: plain HTML shells + client-side JS.

## Status

Legend: `[x]` implemented · `[ ]` not yet · `[~]` partial / next step

### Milestone 1 — Browser STT (T0002, T0003)
- [x] Microphone capture (Web Audio API, hold-to-talk)
- [x] Local Whisper transcription via Transformers.js (Web Worker)
- [x] WebGPU preferred, WASM/CPU fallback
- [x] Spanish (multilingual) model, cached in browser Cache Storage
- [x] Model loaded once and reused across utterances
- [x] Graceful mic / WebGPU / WASM / model / inference errors

### Milestone 2 — Phoenix integration (T0004)
- [x] `POST /api/transcriptions` JSON endpoint
- [x] `Soundai.Conversation.submit_transcript/1` seam for the future LLM relay
- [x] Best-effort send: offline or failure keeps the transcript, never an error state
- [ ] LLM relay through Needle (OpenAI-compatible API)
- [ ] Conversation context / session

### Audio output (T0005)
- [x] Server echoes the text back in the JSON `response` field
- [x] Browser speaks the server's `response` via native `speechSynthesis`
- [x] "Speaking…" state; new press interrupts playback
- [ ] Server-side TTS engine / streaming TTS (open decision, PRD §22)

### Production UX (Milestone 4)
- [x] `/settings` model & language picker (cookie + `?model=` URL override)
- [x] Offline banner + service worker (registered in production)
- [x] Light / dark / system theme toggle
- [~] Browser/E2E tests (the STT flow is verified manually, per TECH_DESCRIPTION §10)
- [ ] Authentication (needed before private conversation history, PRD §14)
- [ ] Rate limiting (before any public deployment, PRD §14)

### Future / backlog
- [ ] LLM conversation (Needle + OpenAI-compatible API)
- [ ] Continuous conversation / voice activity detection
- [ ] Streaming STT (partial transcripts while speaking)
- [ ] Streaming LLM/TTS
- [ ] Interruption handling beyond "stop on next press"
- [ ] Persistent conversation history
- [ ] Offline operation beyond STT

## Run

```sh
mix setup                      # umbrella root
cd apps/soundai
mix phx.server                 # visit http://localhost:4002
```

Benchmark/override STT config with `?model=<hf-model>&language=<lang>` or via
the `/settings` page.

## Test

```sh
cd apps/soundai && mix test
mix precommit                  # compile --warnings-as-errors, format, credo, dialyzer, tests
```

## Docs

- `sdlc/PRD.md` — product requirements
- `sdlc/TECHNICAL_DESCRIPTION.md` — architecture, conventions, gotchas
- `sdlc/tickets/T0002.md` … `T0005.md` — feature tickets