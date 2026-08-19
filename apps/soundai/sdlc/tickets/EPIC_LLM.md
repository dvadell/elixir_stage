----
title: Epic — LLM conversation reply (replace the echo)
----

Replace the server's echo behavior with a real LLM conversation: the transcript
is sent through `branched_llm` (wrapper around ReqLLM) to an OpenAI-compatible
endpoint, and the response is either returned as text (spoken by the browser's
chosen TTS engine) or returned as synthesized audio (server runs LLM + TTS in
one round trip).

Depends on the branched_llm enhancement tickets (BL-01 … BL-03) being released
to a git tag first.

## Desired flow

```text
User speaks
  → Whisper in browser (local STT)
  → transcribed text
  → POST (text mode)  /api/transcriptions
  → POST (audio mode) /api/conversations/audio   (new)
  → Soundai.Conversation (conversation context + LLM via branched_llm)
  → LLM response text
      ├ text mode:  {"ok": true, "response": <LLM text>, "conversation_id": ...}
      │             → browser speaks it via native / local VITS engine
      └ audio mode: WAV (LLM text synthesized by Soundai.TTS/Ortex in-process)
                    → browser plays it
```

Conversation context: the server keeps an in-memory `ReqLLM.Context` per
conversation_id (idle TTL cleanup); the conversation_id travels in a
`soundai_conversation` cookie (server-set, same-origin fetch carries it back),
and is echoed in the JSON body / `X-Conversation-Id` header for robustness.

Reply-mode selection is tied to the existing TTS engine picker (decision):
selecting **"Servidor (Elixir + ONNX)"** ⇒ audio mode (one call, WAV out);
**native / local VITS** ⇒ text mode (LLM text, spoken by that engine).

Default LLM model: `openai/gpt-oss-20b` on `https://integrate.api.nvidia.com/v1`
(verified reachable; `NVIDIA_API_KEY` already in the env). System prompt is a
short Spanish assistant prompt; LLM output is capped to keep TTS latency low.

## Tickets

| # | Title | Area |
|---|-------|------|
| T0012 | Add `branched_llm` dependency + NVIDIA provider config | Infra |
| T0013 | Conversation context store + LLM relay (text mode) | Server |
| T0014 | Audio reply endpoint `/api/conversations/audio` | Server |
| T0015 | Client: reply modes + audio playback + graceful fallback | Client |
| T0016 | LLM error handling, timeouts & conversation reset | Both |
| T0017 | Documentation & open-questions resolution | Docs |

Non-goals (PRD future): streaming LLM/TTS, VAD/continuous conversation,
interruptions, persistent history (DB), multi-provider switching UI,
authentication/rate limiting (noted in PRD §14, out of scope here).

## Verification (epic level)

```sh
cd apps/soundai && mix test
mix precommit            # umbrella root
```

Manual browser check per convention (client flow verified in browser console):
press → speak → hear an LLM answer, with the selected reply mode (server =
audio, native/local = text) and a follow-up question ("¿Y el sábado?") resolved
in context. See each ticket for its own acceptance criteria.