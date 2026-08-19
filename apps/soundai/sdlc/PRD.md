# Product Requirements Document: Voice-First AI Assistant

**Status:** Draft  
**Purpose:** Define the product, target users, core experience, architecture, scope, roadmap, and success criteria.

## 1. Product Summary

This project is a **voice-first AI assistant designed for people who have difficulty using conventional visual computer interfaces**, particularly people with poor eyesight.

The core interaction is intentionally simple:

> Press one large button, speak naturally, and hear the AI's response.

The initial product is an Elixir/Phoenix web application. The screen is primarily a mechanism for starting and monitoring the conversation; **voice is the primary interface**.

The core loop is:

```text
User speaks
    ↓
Browser microphone
    ↓
Local speech-to-text
    ↓
Phoenix / Needle
    ↓
LLM
    ↓
Text-to-speech
    ↓
User hears response
```

## 2. Problem

Conventional AI interfaces are designed around:

- text input;
- reading long responses;
- scrolling;
- menus and buttons;
- visually understanding application state.

These interfaces can be difficult for people with poor eyesight, particularly older users who are not technically sophisticated.

The product should eliminate unnecessary visual interaction and make AI feel more like a conversation with another person.

The user should not need to:

1. Find a text input.
2. Type a question.
3. Read a response.
4. Navigate the UI to ask another question.

Instead:

1. Press one button.
2. Speak.
3. Listen.

## 3. Product Vision

Create an AI assistant that feels as close as possible to **talking to another person**, while being simple enough for someone with limited vision and limited technical experience to use independently.

Long term:

> **An AI assistant that can be operated primarily through speech, with the screen acting as a simple status and safety mechanism rather than the main interface.**

The initial implementation is a web application, but the conversational architecture should not depend on a conventional chat UI.

## 4. Target Users

### Primary users

People who:

- have difficulty seeing conventional interfaces;
- prefer speaking over typing;
- may not be technically sophisticated;
- should not need to understand AI terminology;
- should be able to operate the application with minimal assistance.

The first intended users are older adults.

### Secondary users

The architecture may eventually serve:

- users with visual impairments;
- users who prefer voice interaction;
- users who have difficulty typing;
- users who want a very simple AI interface;
- caregivers or family members assisting another user.

## 5. Product Principles

### Voice first

Voice is the primary interface. Visual UI supports the voice interaction.

### Extreme simplicity

The first screen should contain very little. The main instruction should effectively be:

> Press this button and talk.

### Minimal cognitive load

Users should not need to understand models, tokens, embeddings, RAG, providers, or APIs.

### Fast feedback

The system should make it obvious when it is:

- listening;
- transcribing;
- thinking;
- speaking.

### Graceful failure

Every stage can fail:

```text
Microphone
   ↓
Browser
   ↓
STT
   ↓
Network
   ↓
Needle
   ↓
LLM
   ↓
TTS
   ↓
Audio playback
```

Failures must be communicated in simple language and leave the application usable.

## 6. Core User Experience

### 6.1 Start

The user opens the application and sees one dominant action: **Talk**.

The user presses it. Microphone permission is requested if necessary.

The interface indicates that the assistant is listening.

### 6.2 Speak

The user speaks naturally.

The initial version does not need streaming transcription. The first milestone is:

```text
press → speak → stop → transcribe
```

### 6.3 Speech-to-text

Speech-to-text is performed locally in the browser using:

**Transformers.js + Whisper**

with:

- WebGPU preferred;
- WASM/CPU fallback.

The desired flow is:

```text
Microphone
    ↓
Whisper in browser
    ↓
Text
```

rather than uploading raw audio to the backend for transcription.

The Whisper model should remain loaded for subsequent utterances and use browser caching where possible.

### 6.4 LLM conversation

Once transcription is available:

```text
User speech
    ↓
Browser STT
    ↓
Transcribed text
    ↓
Phoenix
    ↓
Needle
    ↓
OpenAI-compatible LLM API
    ↓
LLM response
```

Needle remains the AI orchestration/retrieval layer. The LLM should be accessed through an OpenAI-compatible interface where practical, avoiding unnecessary coupling to one provider.

### 6.5 Text-to-speech

The response is converted to speech:

```text
LLM response
    ↓
TTS
    ↓
Audio
    ↓
Browser
    ↓
Speaker/headphones
```

The initial priority is:

1. intelligibility;
2. low latency;
3. natural enough speech;
4. reliable playback.

Audio is the primary output. Displayed text is secondary.

## 7. Conversation Model

The assistant should support conversational context.

For example:

```text
User: "What is the weather tomorrow?"

Assistant: "It looks like..."

User: "And Saturday?"
```

The second question should be understood in context.

The initial milestone only requires reliable context within an active conversation. Persistent history can come later.

## 8. Initial UI

The first version should **not** be a conventional chat application.

The main screen should have:

- one large microphone/talk button;
- a clear current-state indicator;
- optional large text showing recent transcription/response for development and accessibility;
- no unnecessary navigation.

Possible states:

```text
IDLE
 ↓
LISTENING
 ↓
TRANSCRIBING
 ↓
THINKING
 ↓
SPEAKING
 ↓
IDLE
```

Errors should return the UI to a usable state.

## 9. Technical Architecture

```text
┌─────────────────────────────────────────────────────────────┐
│                         Browser                             │
│                                                             │
│  Microphone → Audio capture → Transformers.js → Whisper    │
│                                      │                      │
│                              ┌───────┴───────┐              │
│                              │               │              │
│                           WebGPU          WASM/CPU           │
│                              │               │              │
│                              └───────┬───────┘              │
│                                      ↓                      │
│                                     Text                    │
└──────────────────────────────────────┬──────────────────────┘
                                       │
                                       │ HTTPS / WebSocket
                                       ▼
┌─────────────────────────────────────────────────────────────┐
│                    Elixir / Phoenix                         │
│                                                             │
│  LiveView / application session                             │
│                  ↓                                          │
│                Needle                                        │
│                  ↓                                          │
│        OpenAI-compatible LLM API                            │
│                  ↓                                          │
│              Text response                                  │
└──────────────────────────────────────┬──────────────────────┘
                                       │
                                       ▼
                                      TTS
                                       │
                                       ▼
                                    Browser
                                       │
                                       ▼
                                     Audio
```

The exact location of TTS was intentionally left open; it is now resolved:
**server-side synthesis inside Elixir** (in-process ONNX/VITS via `Ortex`, no
separate service) is the default, with browser-side engines (native
`speechSynthesis` and a local Transformers.js VITS worker) available as
fallbacks. The choice can still shift per latency, quality, privacy, and
operational considerations.

## 10. Technology Choices

### Frontend

- Phoenix frontend/assets
- JavaScript
- Web Audio APIs
- Transformers.js
- Whisper
- WebGPU
- WASM fallback

### Backend

- Elixir
- Phoenix
- Phoenix LiveView where appropriate
- Needle

### AI

- Whisper for STT
- OpenAI-compatible API for the LLM
- TTS: server-side synthesis implemented in Elixir (ONNX Runtime via `Ortex`,
  running the `Xenova/mms-tts-spa` VITS model in-process), with browser-side
  engines (native `speechSynthesis`, local Transformers.js VITS) as fallbacks.

The architecture should avoid hard-coding the product to one LLM or TTS provider.

## 11. Privacy

Local STT is an important privacy property.

The desired flow is:

```text
Audio
  ↓
Browser
  ↓
Local Whisper
  ↓
Text
  ↓
Backend
```

Raw microphone audio should not be sent to the backend merely to perform transcription.

The product should eventually document:

- what audio remains local;
- what text is transmitted;
- where conversation history is stored;
- which external AI services receive data.

## 12. Performance

Voice interaction is highly sensitive to latency.

Measure the major components independently:

```text
Microphone capture
       +
STT initialization
       +
STT inference
       +
Network latency
       +
LLM time-to-first-token
       +
TTS generation
       +
Audio playback
```

Important metrics:

- first model load time;
- subsequent transcription latency;
- transcription duration / audio duration;
- browser memory usage;
- WebGPU performance;
- WASM performance;
- LLM latency;
- TTS latency;
- total user-perceived response latency.

The Whisper model should be selected based on actual browser benchmarks, not model quality alone.

## 13. Reliability

### Microphone

Handle:

- permission denied;
- microphone unavailable;
- unsupported browser APIs.

### STT

Handle:

- model download failure;
- insufficient memory;
- WebGPU initialization failure;
- WASM initialization failure;
- inference failure.

### Backend

Handle:

- network interruption;
- Phoenix unavailable;
- Needle failure;
- LLM unavailable;
- LLM timeout.

### TTS

Handle:

- TTS provider unavailable;
- audio playback blocked;
- browser audio failure.

Every failure should leave the application in a recoverable state.

## 14. Security

At minimum:

- production microphone access requires HTTPS;
- authentication should be introduced before exposing private conversation history;
- LLM provider credentials must never be exposed to the browser;
- user-generated text is untrusted input;
- rate limiting should be considered for public deployments;
- audio should not be persisted unless explicitly required.

## 15. Accessibility

Accessibility is a primary product requirement.

The UI should support:

- very large controls;
- high-contrast presentation;
- keyboard activation;
- screen-reader-compatible labels;
- clear focus states;
- minimal navigation;
- state changes compatible with assistive technology.

The main interaction should remain usable without looking at the screen.

The user should never have to read a status message to understand what is happening.

Audio cues may eventually communicate important state transitions.

## 16. MVP

### MVP user story

> As a user, I want to press a large button, speak naturally, and hear an AI answer without having to type or read a conventional chat interface.

### MVP flow

```text
Open application
    ↓
Press microphone
    ↓
Speak
    ↓
Stop recording
    ↓
Whisper transcribes locally
    ↓
Text sent to Phoenix
    ↓
Needle / LLM generates response
    ↓
TTS generates audio
    ↓
User hears response
```

### MVP acceptance criteria

- User can start a voice interaction with one obvious action.
- Browser can access the microphone.
- Whisper runs locally in the browser.
- WebGPU is used when available.
- WASM/CPU is used as fallback.
- Spanish speech can be transcribed.
- Transcription reaches Phoenix.
- Phoenix sends text through Needle to an LLM.
- The response is converted to speech.
- The response can be heard in the browser.
- The user can repeat the process for another turn.
- Conversation context is maintained during the session.
- Common errors are presented clearly.
- The UI remains extremely simple.

## 17. Roadmap

### Milestone 1 — Browser STT proof of concept

Implement:

- microphone capture;
- Transformers.js;
- Whisper;
- WebGPU;
- WASM fallback;
- local transcription;
- basic performance measurement.

Deliverable:

```text
microphone → Whisper → text
```

### Milestone 2 — Phoenix integration

Implement:

- Phoenix UI;
- LiveView integration;
- transcription transmission;
- conversation session;
- Needle integration.

Deliverable:

```text
microphone → Whisper → Phoenix → Needle → LLM → text
```

### Milestone 3 — TTS

Add TTS and browser playback.

Deliverable:

```text
microphone
    ↓
Whisper
    ↓
Needle / LLM
    ↓
TTS
    ↓
speaker
```

At this point the core product loop exists.

### Milestone 4 — Production UX

Improve:

- loading states;
- error handling;
- accessibility;
- audio feedback;
- model caching;
- browser compatibility;
- Web Worker usage;
- performance.

### Milestone 5 — Conversation quality

Improve:

- conversation memory;
- interruption handling;
- better turn-taking;
- response latency;
- prompt/system behavior;
- context management.

## 18. Future Features

These are deliberately outside the MVP.

### Continuous conversation

```text
listen → understand → answer → listen → ...
```

### Voice activity detection

Automatically detect when the user has stopped speaking.

### Interruptions

Allow the user to interrupt the assistant while it is speaking.

### Streaming STT

Consume partial transcription while the user is speaking.

### Streaming LLM/TTS

Begin speaking before the complete LLM response has been generated.

### Persistent conversations

Continue conversations across sessions.

### Personal memory

Allow the assistant to remember useful user-provided information.

### Caregiver/family features

Allow a family member to configure or assist with the assistant without complicating the primary user's interface.

### Multiple AI providers

Support different OpenAI-compatible LLM endpoints.

### Offline operation

Potentially allow some or all of the assistant to work without an internet connection, depending on the eventual LLM and TTS architecture.

## 19. Non-Goals

The project is not initially intended to be:

- a general-purpose chat UI;
- a social network;
- a productivity suite;
- a complex accessibility dashboard;
- a native mobile application;
- a general-purpose voice platform;
- a model-training project.

The product should resist feature creep that makes the core interaction harder to use.

## 20. Key Product Decisions

### Browser-side STT

Use local Whisper inference rather than sending microphone audio to a server.

**Reason:** privacy, reduced audio infrastructure, and a simpler backend.

### Transformers.js

Use Transformers.js as the initial browser inference layer.

**Reason:** it provides a practical JavaScript interface to browser-compatible models and supports WebGPU and WASM execution.

### WebGPU with WASM fallback

Prefer WebGPU but never require it.

**Reason:** WebGPU can provide better inference performance on capable hardware, while WASM provides broader compatibility.

### Phoenix + Needle

Keep Phoenix as the application backend. The AI orchestration layer previously
sketched as "Needle" is now **`branched_llm`** (a wrapper around ReqLLM),
accessed through an OpenAI-compatible interface (NVIDIA endpoint, default model
`openai:openai/gpt-oss-20b`, T0012). The OpenAI-compatible commitment in §6.4
stands.

### Voice-first UI

Do not start by building a traditional chat interface.

The primary interaction remains:

```text
Talk → Listen
```

## 21. Success Metrics

The most important metric is not model quality in isolation.

The product succeeds if a target user can use it independently.

### Usability

Measure:

- Can the user start a conversation without assistance?
- Can the user understand when the system is listening?
- Can the user understand when the assistant is responding?
- Can the user recover from common errors?

### Latency

Measure:

- microphone → transcription;
- transcription → LLM response (bounded by the 30 s LLM timeout — count 504s);
- LLM → TTS;
- total response latency.

### STT quality

Evaluate realistic speech, especially:

- Spanish;
- older speakers;
- different speaking speeds;
- background noise;
- ordinary conversational language.

### Reliability

Measure:

- successful voice turns;
- microphone failures;
- STT failures;
- LLM failures (broken down by reason: `:llm_unavailable` → 502,
  `:llm_timeout` → 504);
- TTS failures.

## 22. Open Questions

These should be resolved through implementation and measurement rather than prematurely locking the architecture:

1. Which Whisper model provides the best quality/latency/memory tradeoff?
2. Should Whisper run in a Web Worker? — **yes** (T0002/T0003).
3. Which TTS engine provides the best latency, quality, privacy, and cost? —
   **resolved** to the `Xenova/mms-tts-spa` VITS model (T0008 benchmark);
   Supertonic-TTS-2-ONNX was evaluated and removed.
4. Should TTS run locally or on the backend? — **resolved**: server-side
   in-process Elixir (ONNX/Ortex) by default, with browser-side engines
   (native + local VITS) as fallbacks (T0009/T0010).
5. How should conversation history be persisted? — **resolved for the epic**:
   active-session only, in-memory per `conversation_id` with an idle TTL
   (`Soundai.Conversation.Store`, T0013); the `soundai_conversation` cookie
   carries the id; "Nueva conversación" / `reset: true` start fresh (T0016).
   Persistent history remains future work.
6. How should users interrupt an assistant response? — **resolved for the epic**:
   a new press cancels playback and starts recording; the speaking watchdog
   bounds hangs (T0011/T0015).
7. Should voice activity detection replace explicit recording controls?
8. How much of the system should eventually work offline? — **resolved for the
   epic**: STT is fully offline; the LLM round trip (text and audio reply modes)
   is online-only and fails quietly offline (T0013–T0016).
9. What browser/device baseline should officially be supported?
10. What is the appropriate long-term authentication model? — **out of scope**
    for this epic; PRD §14 (rate limiting/auth) remains before public deployment.
11. Which LLM model/provider should be used? — **resolved**: NVIDIA
    OpenAI-compatible endpoint with `openai:openai/gpt-oss-20b` as the default
    model, reached through `branched_llm` (a wrapper around ReqLLM) — see
    `config/config.exs` + `config/runtime.exs` (T0012). The orchestration layer
    previously sketched as "Needle" is now `branched_llm`; the OpenAI-compatible
    commitment in §6.4 is kept.

## 23. Product Definition

In one sentence:

> **A simple, voice-first AI assistant that lets people with limited vision talk naturally with an LLM and hear its responses, without needing to type or read a conventional chat interface.**

The first implementation should remain deliberately small:

```text
                 SPEAK
                   ↓
        Browser-local Whisper
                   ↓
                 TEXT
                   ↓
            Phoenix / Needle
                   ↓
                  LLM
                   ↓
                  TTS
                   ↓
                LISTEN
```

Everything else is secondary until this loop is fast, reliable, understandable, and pleasant to use.

