# Soundai

Voice-first AI assistant web app (a Phoenix umbrella app alongside `soundpanel`).
One big button: **press → speak → release**, and the assistant transcribes your
speech locally, sends the text to the server, and speaks the server's reply back
to you. Built for people who prefer talking over reading (see the PRD).

## What works

Speech is transcribed **in the browser** — raw microphone audio never leaves the
device. The transcribed text is POSTed to Phoenix (together with client
context: the browser's local date/time, timezone and — when permitted —
geolocation), which relays it to an **LLM**
(via `branched_llm`, NVIDIA OpenAI-compatible endpoint), keeps **per-conversation
context** server-side, and returns the assistant's reply. The browser then
speaks that reply through a pluggable TTS engine:

- **text mode** (native `speechSynthesis` or a local VITS model): `POST
  /api/transcriptions` returns the LLM text, which the chosen engine speaks.
- **audio mode** ("Servidor (respuesta de voz)"), default: `POST
  /api/conversations/audio` runs the LLM **and** synthesizes the answer with the
  in-process Elixir TTS (Ortex/ONNX) in one round trip, returning a WAV the
  browser plays. If the server TTS model is absent (503) the client falls back
  to text mode for that utterance.

```text
press → speak → release
    → Whisper (WebGPU / WASM) transcribes locally
    → POST /api/transcriptions {text, language, date, time, timezone,
                                latitude?, longitude?}      (text mode)
        → {"ok": true, "response": <LLM text>, "conversation_id": "..."}
        → TTS engine speaks the reply (native / local VITS)
    → POST /api/conversations/audio {text, language, ...}   (audio mode, default)
        → 200 audio/wav (LLM + server TTS in one call) + X-Conversation-Id
        → browser plays the WAV
    (the soundai_conversation cookie keeps follow-up turns in context;
     "Nueva conversación" clears it for a fresh thread)
```

- **Offline-first**: once the page shell and the Whisper model are cached, STT
  keeps working with no network. The transcript send is best-effort and fails
  quietly (transcript stays visible, Spanish quiet note).
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
- [x] `Soundai.Conversation.submit_transcript/2` seam for the LLM relay
- [x] Best-effort send: offline or failure keeps the transcript, never an error state
- [x] LLM relay through `branched_llm` (NVIDIA OpenAI-compatible API, T0012/T0013)

### LLM conversation (T0013–T0016)
- [x] Per-conversation context store (`Soundai.Conversation.Store`, 30 min idle TTL)
- [x] Real LLM answers with Spanish voice-assistant system prompt; replies are
      stripped of Markdown/emoji and unit symbols spelled out
      (`Soundai.Conversation.SpeechText`: `°C` → "grados", `%` → "porciento")
      and capped
      at 500 chars so TTS never reads "asterisk" out loud; raw responses are
      logged at info level for debugging
- [x] `POST /api/conversations/audio`: LLM + server TTS in one round trip (WAV)
- [x] Client reply modes tied to the TTS picker; audio-mode 503 → text fallback
- [x] Bounded latency (LLM 30 s timeout) + speaking/send watchdogs (no hangs)
- [x] Spanish quiet notes for LLM/TTS failures; "Nueva conversación" reset
      (client cookie + server `reset: true`)
- [x] Error vocabulary: `:llm_unavailable`, `:llm_timeout`, `:empty`,
      `:too_long`, `:invalid` → JSON (502/504/422) in both controllers
- [x] Date/time + geolocation relayed to the LLM: each turn's message carries a
      bracketed context block with the **browser's** local date and time (plus
      its IANA timezone name) and, when the user grants permission once per
      page load, their approximate GPS coordinates; the system prompt stays
      exactly as configured
- [x] First LLM tool: **weather** (`Soundai.Conversation.Tools.Weather`) —
      Open-Meteo, free and keyless; the tool is offered on every turn
      (`config :soundai, Soundai.Conversation, :llm_tools`); it also accepts
      the user's coordinates, so "¿qué tiempo hace aquí?" works

### Audio output (T0005)
- [x] Server echoes the text back in the JSON `response` field
- [x] Browser speaks the server's `response` via native `speechSynthesis`
- [x] "Speaking…" state; new press interrupts playback

### Server-side TTS (T0009, T0010)
- [x] In-process TTS inside Elixir: `Soundai.TTS` synthesizes with **Ortex**
      (ONNX Runtime) running the same `Xenova/mms-tts-spa` VITS model the
      browser uses (`priv/tts/`)
- [x] `POST /api/tts` returns `audio/wav` (+ `X-TTS-Duration-Ms` / `X-TTS-Model`
      headers); 422/503 on invalid text or missing model
- [x] Requests serialized through the `Soundai.TTS.OrtexServer` GenServer
      (ONNX sessions are not safe for concurrent runs)
- [x] "Servidor (respuesta de voz)" option in `/settings`, persisted via the
      `soundai_tts` cookie; audio mode is the server reply path
- [ ] Streaming TTS (open decision, PRD §22)

### Production UX (Milestone 4)
- [x] `/settings` model & language picker (cookie + `?model=` URL override)
- [x] Offline banner + service worker (registered in production)
- [x] Light / dark / system theme toggle
- [~] Browser/E2E tests (the STT flow is verified manually, per TECH_DESCRIPTION §10)
- [ ] Authentication (needed before private conversation history, PRD §14)
- [ ] Rate limiting (before any public deployment, PRD §14)

### Future / backlog
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

Server TTS needs the ONNX model at `apps/soundai/priv/tts/model.onnx` (default;
override with `SOUNDAI_TTS_MODEL_PATH`). Without it, the server TTS returns 503
and audio mode falls back to text mode in the browser.

The LLM needs `NVIDIA_API_KEY` (and optionally `LLM_MODEL` / `LLM_BASE_URL`
overrides; see `config/runtime.exs`). The default model is
`openai:openai/gpt-oss-20b` on the NVIDIA endpoint. The effective latency budget
per utterance is: local STT + LLM timeout (30 s, configurable
`llm_timeout_ms`) + TTS synthesis; replies are capped at 500 chars to keep TTS
latency sane.

## Test

```sh
cd apps/soundai && mix test
mix precommit                  # compile --warnings-as-errors, format, credo, dialyzer, tests
```

## Docs

- `sdlc/PRD.md` — product requirements
- `sdlc/TECHNICAL_DESCRIPTION.md` — architecture, conventions, gotchas
- `sdlc/tickets/` — active epic (EPIC_LLM.md, next tickets)
- `sdlc/tickets/done/` — implemented tickets T0002.md … T0017.md