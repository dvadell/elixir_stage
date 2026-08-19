# Soundai — Technical Description

Voice-first speech-to-text web app: a single microphone button that transcribes
Spanish speech locally in the browser using **Whisper** via **Transformers.js**
(on WebGPU or WASM/CPU), shows the transcript on screen, relays it to an **LLM**
(`branched_llm` → NVIDIA OpenAI-compatible endpoint), and speaks the assistant's
reply through a pluggable reply path: either a **text mode** (native
`synthesis` / local Transformers.js VITS worker) or the **audio mode**
(in-process Elixir TTS, `POST /api/conversations/audio`, which runs the LLM and
the ONNX/Ortex VITS model in a single round trip).

It is deliberately **offline-first and client-side** for STT: there is **no
Phoenix LiveView / websocket** at runtime. The server only renders static HTML
shells and accepts JSON/audio endpoints; every interaction (mic capture, model
load, inference, UI state) happens in the browser. Once the page and the speech
model are cached, STT keeps working with no network at all. The transcribed
**text** is POSTed to the server as a best-effort call — STT never depends on it;
the LLM round trip (both reply modes) is online-only.

`soundai` lives in a Phoenix umbrella alongside a sibling app (`soundpanel`).

---

## 1. High-level architecture

```text
Browser
  |
  | plain HTML from Phoenix (no LiveView, no websocket)
  v
app.js (entry point, esbuild bundle)
  |-- mountVoiceAssistant()  -> /          (voice assistant page)
  |-- mountSTTSettings()     -> /settings  (STT + TTS picker page)
  |-- mountTTSSettings()     -> /settings  (TTS engine picker page)
  |-- initOfflineBanner()                  (online/offline banner)
  |-- initThemeToggle()                    (light/dark/system toggle)
  |-- initServiceWorker()                  (production only)

voice_assistant.js (main thread controller)
  |
  | microphone audio (raw PCM, 16 kHz mono float32)
  v
whisper_worker.js (Web Worker, Transformers.js + Whisper)
  |--> WebGPU (preferred) --> WASM/CPU (fallback)
  v
transcribed text -> rendered into the DOM by voice_assistant.js
  |
  | POST /api/conversations/audio {text, language}   (audio mode, default)
  |  or POST /api/transcriptions {text, language}    (text mode)
  v
```

### 1.1 Audio mode (T0014/T0015) — one server round trip

```text
voice_assistant.js  -- POST /api/conversations/audio {text, language} (+ soundai_conversation cookie)
      |
      v
SoundaiWeb.ConversationAudioController
      | Soundai.Conversation.submit_transcript(text, conversation_id)   (LLM)
      | Soundai.TTS.synthesize(response_text, language)                 (Ortex/VITS)
      v
200 audio/wav  + X-Conversation-Id, X-TTS-Duration-Ms, X-TTS-Model
      |           + Set-Cookie: soundai_conversation=<id>
      v
ServerTTSEngine.playWav -> AudioContext.decodeAudioData -> speaker
```

### 1.2 Text mode (T0013/T0015)

```text
voice_assistant.js  -- POST /api/transcriptions {text, language} (+ cookie)
      |
      v
SoundaiWeb.TranscriptionController -> Soundai.Conversation.submit_transcript(text, id)
      |
      v
{"ok": true, "response": <LLM text>, "conversation_id": "...", "language": "..."}
      |
      v
Browser tts_engine.js -> selected engine -> speaker
      |-- native (speechSynthesis) / local Transformers.js VITS worker
```

### 1.3 The LLM layer (T0012/T0013)

`Soundai.Conversation.submit_transcript/2` is the single conversation seam. It
validates the input, loads/creates the per-conversation `ReqLLM.Context` in the
in-memory `Soundai.Conversation.Store` (idle TTL, default 30 min), relays the
text through an injectable adapter (default `Soundai.Conversation.LLM` →
`BranchedLLM.Chat.send_message/3` with `timeout: llm_timeout_ms`, default 30 s),
persists the updated context, and returns `{:ok, text, conversation_id}` or
`{:error, reason}` — never raising. Replies are capped at
`max_response_chars` (500 + "…"). The Spanish voice-assistant system prompt,
timeout, cap and TTL are configurable under `config :soundai,
Soundai.Conversation`. Tests inject `Soundai.Conversation.LLM.FakeAdapter`
(same pattern as `Soundai.TTS`).

`branched_llm` is a git dependency (`dvadell/branched_llm`, tag `v0.3.1`, pinned
in `mix.lock`; its own prep work lives in `branched_llm/sdlc/tickets/` BL-01…03).
NVIDIA OpenAI-compatible config lives in `config :branched_llm` (provider
`:openai` with the NVIDIA `base_url` and `{:system, "NVIDIA_API_KEY"}`); the
default model is `openai:openai/gpt-oss-20b`, overridable via `LLM_MODEL` /
`LLM_BASE_URL` (see `config/runtime.exs`). Per-call timeout handling comes from
BL-03 and surfaces as `:llm_timeout`.

Audio capture never leaves the browser; only the transcribed **text** is sent to
the server. The Phoenix backend serves:

- HTML shells for `/` and `/settings`
- the built JS/CSS bundles
- `service_worker.js` (offline caching)

Error vocabulary: `:empty` / `:too_long` / `:invalid` → 422, `:llm_unavailable`
→ 502, `:llm_timeout` → 504, TTS `:not_ready` → 503 (audio mode). See §3.1.

Server-side TTS (`/api/tts` and the audio-mode reply) is an **optional,
in-process** feature: when a model file is present it is synthesized inside
`soundai` with Ortex; when it is absent those endpoints report `503` (the audio
endpoint also returns the LLM text so the client can fall back to text mode).
There is no standalone TTS service.

## 2. Repository layout

```text
apps/soundai/
├── assets/
│   ├── css/app.css                 Tailwind v4 + daisyUI themes, [hidden] rule
│   ├── js/
│   │   ├── app.js                  entry point, boots the client modules
│   │   ├── voice_assistant.js      main-thread voice UI controller + state machine
│   │   ├── settings.js             /settings STT + TTS picker controllers
│   │   ├── tts_config.js           local TTS model/defaults (single source)
│   │   ├── tts_engine.js           pluggable TTS engine registry (native, server, local VITS)
│   │   ├── tts_worker.js           Web Worker: Transformers.js VITS pipeline
│   │   ├── whisper_config.js       model/language/dtype defaults (single source)
│   │   └── whisper_worker.js       Web Worker: Transformers.js Whisper pipeline
│   ├── package.json                only @huggingface/transformers
│   └── vendor/                     heroicons plugin, topbar (unused)
├── lib/soundai/
│   ├── application.ex             OTP application / supervisor tree
│   ├── conversation.ex            LLM relay seam: submit_transcript/2 (validation,
│   │                               adapter injection, error vocabulary, reply cap)
│   ├── conversation/
│   │   ├── llm.ex                 default LLM adapter -> BranchedLLM.Chat.send_message/3
│   │   └── store.ex               per-conversation context store (GenServer, idle TTL)
│   ├── mailer.ex
│   └── tts/
│       ├── tts.ex                 server-side TTS seam: synthesize/2 (Ortex)
│       ├── tts/ortex_server.ex    GenServer owning the ONNX session (serialized calls)
│       ├── tts/vits_tokenizer.ex  char-level tokenizer mirroring HF VitsTokenizer
│       └── tts/wav.ex             Float32 waveform -> 16 kHz PCM WAV encoder
├── lib/soundai_web/
│   ├── router.ex                  get "/", get "/settings", post /api/{transcriptions,tts,conversations/audio}
│   ├── endpoint.ex                 COOP/COEP headers, static serving, no /live socket
│   ├── controllers/
│   │   ├── home_controller.ex      renders the voice assistant shell
│   │   ├── home_html/              home page templates (HTML module)
│   │   ├── settings_controller.ex  renders the STT + TTS settings shell
│   │   ├── settings_html/          settings templates
│   │   ├── transcription_controller.ex  POST /api/transcriptions JSON endpoint
│   │   ├── conversation_audio_controller.ex  POST /api/conversations/audio WAV endpoint
│   │   └── tts_controller.ex       POST /api/tts WAV endpoint
│   └── components/
│       ├── layouts.ex              app layout, flash_group, theme_toggle
│       └── layouts/root.html.heex  <head>, offline banner, theme script
├── priv/
│   ├── static/
│   │   ├── service_worker.js       offline app-shell service worker
│   │   └── assets/                 built bundles (gitignored, generated)
│   └── tts/                        server TTS model (gitignored): model.onnx,
│                                   tokenizer.json, config.json
├── sdlc/tickets/                   active epic (EPIC_LLM.md, next tickets)
│   └── done/                       implemented tickets T0002.md–T0017.md
└── test/
    ├── soundai/                    unit tests (conversation, tts, vits_tokenizer, wav)
    ├── soundai_web/controllers/    controller tests (home, settings, transcriptions,
    │                               conversation_audio, tts)
    └── support/                    tts_fake_adapter.ex, conversation_fake_adapter.ex
                                    (test adapters injected into Soundai.TTS / Conversation)
```

> Note: `apps/soundai/lib/soundai_web.ex` still defines `live_view`/`live_component`
> helpers and `mix.exs` still depends on `phoenix_live_view`. That is **compile
> time only** — Phoenix 1.8's HEEx/`Phoenix.Component` template system ships in
> `phoenix_live_view`, so the dep is required. There is **no** `/live` socket, no
> `LiveSocket`, and no colocated hooks anymore.

## 3. Routes

`lib/soundai_web/router.ex` — plain controller actions, no `live` routes:

| Route | Controller | Renders |
|------------|-----------------|--------------------------------------------|
| `GET /`          | `HomeController.index`    | `home_html/index.html.heex` (full-screen voice assistant) |
| `GET /settings`  | `SettingsController.index`| `settings_html/index.html.heex`            |
| `POST /api/transcriptions` | `TranscriptionController.create` | JSON envelope `{"ok": true, "response": <LLM text>, "conversation_id": ..., "language": ...}` (no template) |
| `POST /api/tts`  | `TTSController.create`     | `audio/wav` bytes + `X-TTS-Duration-Ms` / `X-TTS-Model` headers (no template) |
| `POST /api/conversations/audio` | `ConversationAudioController.create` | `audio/wav` (LLM + server TTS) + `X-Conversation-Id` / `X-TTS-Duration-Ms` / `X-TTS-Model` headers + cookie (no template) |

`service_worker.js` is a static file served from `priv/static/` (added to
`SoundaiWeb.static_paths/0`). `Plug.Static` `only:` includes it.

### 3.1 LLM conversation endpoints (T0013/T0014)

Both JSON endpoints share the same `:api` pipeline (`:accepts`, `:fetch_cookies`),
the same conversation seam (`Soundai.Conversation.submit_transcript/2`), and the
same error vocabulary:

| Reason (`Soundai.Conversation`) | HTTP | JSON body |
|---------------------------------|------|-----------|
| `{:ok, text, id}`               | 200/201 | success payload (text mode) or WAV (audio mode) + `conversation_id` + cookie |
| `:empty` / `:too_long` / `:invalid` | 422 | `{"errors": {"text": "..."}}` |
| `:llm_unavailable`              | 502 | `{"errors": {"text": "LLM is unavailable"}}` |
| `:llm_timeout`                  | 504 | `{"errors": {"text": "LLM timed out"}}` |
| TTS `:not_ready` (audio mode)   | 503 | `{"errors": {"text": "server TTS is not ready"}, "response": <LLM text>, "conversation_id": id}` |

The client renders **short Spanish** quiet notes from the status code (never the
error state): 504 → "El asistente tardó demasiado…", 502/network → "No pude
conectar con el asistente…", 503 → "El servidor no pudo generar audio…". A body
`reset: true` (either endpoint) deletes the stored context for the incoming id
and returns a fresh `conversation_id`; the "Nueva conversación" button clears
the cookie client-side.

### 3.2 Latency budget

Per utterance: **local STT** (browser, no network) → **LLM** with a bounded
timeout (`llm_timeout_ms`, default 30 s, passed to
`BranchedLLM.Chat.send_message/3`; surfaced as `:llm_timeout` by BL-03) → **TTS**
(server synthesis or browser playback). Replies are capped at
`max_response_chars` (500) so TTS latency stays bounded. The client also
enforces its own bounds: a 15 s fetch timeout and a speaking watchdog
(5–30 s by text length, or the server's `X-TTS-Duration-Ms` + 2 s in audio
mode) so the UI can never stall (T0011/T0015).

## 4. The voice assistant page (`/`)

Template: `lib/soundai_web/controllers/home_html/index.html.heex`
Controller: `assets/js/voice_assistant.js`

### 4.1 Server-rendered shell

The template renders **all** UI states up front; JS toggles them. Never add
Tailwind's `hidden` class to an element whose visibility is driven by JS — the
JS toggles the `hidden` **attribute**, and `app.css` has a
`[hidden] { display: none !important }` rule so the attribute always wins over
display classes (a Tailwind `hidden` class silently beats the attribute).

| DOM id                | Role                                             |
|-----------------------|--------------------------------------------------|
| `#voice-assistant`    | root container; `mountVoiceAssistant()` targets it |
| `#model-loading`      | shown while the model is downloading/loading     |
| `#model-loading-progress` / `#model-loading-progress-value` | download % on the loading screen |
| `#record-button`      | the full-screen "Hold to talk" button            |
| `#voice-label`        | current state label text                         |
| `#listening-ping`, `#listening-dot` | pulsing indicators while recording  |
| `#record-icon`        | mic icon wrapper (scaled when recording)         |
| `#preparing-hint` / `#preparing-progress` | "Preparing Whisper… N%" hint    |
| `#voice-result`       | bottom transcript/error panel                    |
| `#voice-error`, `#voice-transcript` | error vs transcript text           |
| `#voice-send-status`  | non-blocking "Sending…"/quiet note under the transcript |
| `#reset-conversation` | "Nueva conversación" button: clears the `soundai_conversation` cookie |

Server default state: loading screen visible, record button hidden. JS takes
over on boot (`start()` → `setState("loading")` → `preload()`).

### 4.2 Client-side state machine

`VoiceAssistantController` in `voice_assistant.js` drives the DOM directly.
States: `loading → idle → listening → transcribing → sending → speaking → result | error → idle`.

- `render()` recomputes every element from `{state, progress, transcript, error}`.
- Pointer handlers live on the root container; presses that start on an `<a>`
  (the settings link) are ignored so navigation still works.
- `preload()` loads the model before the button is interactive; tapping while
  loading/errored re-triggers the preload.
- On a transcription result, `sendTranscript/1` dispatches by the configured
  TTS engine (T0015):
  - **audio mode** (`server` engine): one POST to `/api/conversations/audio`;
    on 200 the returned WAV is played via `ServerTTSEngine.playWav/2`; on 503
    (server TTS model absent) it falls back to text mode for that utterance
    with a Spanish quiet note; on 422/502/504/network the transcript stays
    under a Spanish quiet note. The UI never enters the error state.
  - **text mode** (native / local VITS): POST to `/api/transcriptions` and the
    reply text is spoken by that engine (with native fallback).
- The send is best-effort: on success the note disappears; on failure the
  transcript stays visible under a quiet note. When `navigator.onLine` is
  false the POST is skipped entirely.
- Every wait is bounded (T0011/T0015): `fetchWithTimeout` aborts after 15 s,
  and a speaking watchdog (5–30 s by text length, or the server's
  `X-TTS-Duration-Ms` + 2 s in audio mode) forces the `result` state if
  `onend` never fires. Both are cleared on `pointerdown`/`stop`.
- Starting a new recording (`pointerdown`) calls `ttsEngine.cancel()` and
  clears the watchdog so the user can interrupt the assistant mid-speech.

### 4.3 Audio capture

- `pointerdown` → `getUserMedia({audio: true})`, `AudioContext` +
  `ScriptProcessor` collects raw `Float32Array` PCM chunks.
- `pointerup` → chunks are concatenated, resampled to **16 kHz mono** via
  `OfflineAudioContext`, and sent to the worker for transcription.
- Utterances shorter than `WHISPER_CONFIG.minUtteranceMs` (200 ms) are skipped.
- Permission denied / no mic / busy mic map to friendly messages via
  `friendlyMicError/1`.

## 5. Whisper worker

`assets/js/whisper_worker.js` runs Transformers.js inference off the main
thread. It is a separate esbuild entry point and must keep its **stable URL**
`/assets/js/whisper_worker.js` (the main thread constructs
`new Worker("/assets/js/whisper_worker.js")`; the service worker precaches that
exact path).

### 5.1 Message protocol (main thread ⇄ worker)

```text
main -> worker  {type: "init", options: {device, model, language, dtype}}
                {type: "transcribe", id, audio: Float32Array, language}   (transferable)
worker -> main  {type: "progress", status, progress, ...}   (model download)
                {type: "ready", device}
                {type: "fallback", from, to, error}         (webgpu -> wasm)
                {type: "result", id, text, device, inferenceMs}
                {type: "error", stage, error}
```

### 5.2 Device selection & fallback

1. Main thread probes `navigator.gpu` → prefers `webgpu`, else `wasm`.
2. If WebGPU init fails at runtime the worker retries with WASM and posts
   `fallback`.
3. Per-device dtype comes from `WHISPER_CONFIG.dtype`; the encoder stays `fp32`
   (int8 garbles accented audio), only the decoder is quantized.

### 5.3 Model config — single source of truth

`assets/js/whisper_config.js` exports `WHISPER_CONFIG`:

- `model`: default `onnx-community/whisper-base`
- `language`: default `spanish`
- `dtype`: `{webgpu: {encoder fp32, decoder fp16}, wasm: {encoder fp32, decoder q8}}`
- `minUtteranceMs`: 200

Settings page (`/settings`) writes a `soundai_model` cookie. Precedence at load:
**URL param (`?model=`) > cookie > WHISPER_CONFIG default**. Same for
`language`. This is how benchmarks A/B models via `?model=...&language=...`.

## 6. Settings page (`/settings`)

- Template `settings_html/index.html.heex` renders two selects:
  1. `<select id="stt-model">` — STT model picker (Whisper models).
  2. `<select id="tts-model">` — TTS engine picker (local VITS model, `server`
     — the in-process Elixir engine — and the native API).
  Each `<option>` carries `data-label` and `data-desc` so the client can render
  descriptions/saved confirmation without the server.
- `assets/js/settings.js` exports `mountSTTSettings` and `mountTTSSettings`,
  both backed by a shared `mountSelect` helper. The STT mounter reads/writes
  the `soundai_model` cookie; the TTS mounter reads/writes the `soundai_tts`
  cookie. Both show descriptions and confirm the save — all client-side.
- The list of STT models lives in `SettingsHTML` (`@models` → `models/0`).
- The list of TTS engine options lives in `SettingsHTML` (`@tts_models` →
  `tts_models/0`).
- TTS engine selection precedence: **URL param (`?tts=...`) > `soundai_tts`
  cookie > `"native"` default**. Unknown engine ids fall back to the native
  engine with a console warning (see `tts_engine.js`).

## 7. Offline strategy (three independent layers)

1. **Service worker** — `priv/static/service_worker.js`, registered only in
   production from `app.js`. Precaches the stable shell
   (`whisper_worker.js`, images) and best-effort pages; network-first for
   navigations, stale-while-revalidate for same-origin assets. Bump
   `CACHE_NAME` (e.g. `soundai-shell-v2`) when the shell layout changes.
   Cross-origin requests are never intercepted.
2. **Model caching** — Transformers.js caches model weights and the WASM
   runtime in the browser **Cache Storage** (`env.useBrowserCache` /
   `env.useWasmCache` in `whisper_worker.js`). This is what makes STT fully
   offline after the first download.
3. **No server dependency** — the UI state machine is client-side, so dropping
   the network never freezes the page. An `#offline-banner` ("Offline — speech
   recognition still works locally") is shown when `navigator.onLine` flips.
   Transcription keeps working fully offline; only the transcript send to
   `/api/transcriptions` is best-effort and fails quietly (see §4.2). The
   `server` TTS engine needs a network round trip; on failure the assistant
   falls back to the native engine with a quiet note.

For full offline: visit the page once online (populates model + shell cache),
then reload offline.

## 8. Cross-origin isolation

`endpoint.ex` sets:

- `Cross-Origin-Opener-Policy: same-origin`
- `Cross-Origin-Embedder-Policy: credentialless`

`credentialless` unlocks onnxruntime-web's WASM thread pool
(SharedArrayBuffer) while still allowing model/WASM fetches from the Hugging
Face CDN without CORP headers. Do not switch to `require-corp` unless the CDN
serves CORP.

## 9. Build pipeline

- **esbuild** (`config/config.exs`, `:esbuild` `:soundai`): bundles
  `js/app.js`, `js/whisper_worker.js`, and `js/tts_worker.js` →
  `priv/static/assets/js/`. Output is gitignored; always rebuild before testing
  served assets.
- **Tailwind v4** (`assets/css/app.css`): no `tailwind.config.js`; uses the
  `@import "tailwindcss" source(none)` + `@source` form. Icons come from the
  `heroicons` vendor plugin; components are hand-written (no daisyUI
  components beyond the theme tokens).
- The `[hidden] { display: none !important }` rule in `app.css` is load-bearing
  for the JS-driven visibility toggling.

Commands (from umbrella root or `apps/soundai`):

```sh
mix assets.build   # tailwind + esbuild
mix assets.deploy  # minified + phx.digest (production)
mix precommit      # compile --warnings-as-errors, format, credo --strict, dialyzer, tests
```

## 10. Testing

- Controller tests in `apps/soundai/test/soundai_web/controllers/`
  (`HomeControllerTest`, `SettingsControllerTest`, `TranscriptionControllerTest`,
  `TTSControllerTest`): assert the server-rendered shell (element ids, links,
  option values, no header on settings) and the JSON envelope/validation of
  `POST /api/transcriptions` (valid → 201 `{"ok": true, "response": <text>}`,
  missing/blank/oversized text → 422) and `POST /api/tts` (valid → 200
  `audio/wav` with headers, 422 on bad text, 503 when no model is configured).
  `TTSControllerTest` injects a fake adapter into `Soundai.TTS` so no ONNX model
  is needed in tests.
- `Soundai.TTS` unit tests live in `test/soundai/` (`tts_test.exs`,
  `vits_tokenizer_test.exs`, `wav_test.exs`).
- `layouts_test.exs` / `core_components_test.exs` still use
  `Phoenix.LiveViewTest.render_component` (the dep remains for compile-time
  components).
- There are **no browser/E2E tests** for the client-side state machine; the
  STT flow is verified manually in the browser console
  (`[soundai] transcript: ...`).

```sh
cd apps/soundai && mix test                      # soundai only
cd /home/developer/elixir_stage && mix test      # whole umbrella
mix precommit
```

## 11. Deployment

- The umbrella ships both apps in one release (`elixir_stage`). `soundai` runs
  on port **4002** (`SOUNDAI_PORT`), `soundpanel` on 4001.
- Dockerfile builds assets for both apps (`mix assets.deploy`), then
  `mix release elixir_stage`. `docker-compose.yml` publishes both ports and
  expects `PHX_HOST=localhost` (prod force-SSLs non-localhost hosts).
- In production the service worker is registered and digested assets are
  fingerprinted; the un-hashed `whisper_worker.js` / `tts_worker.js` stay served
  at their stable URLs so `new Worker(...)` keeps working.
- Server TTS runs **in-process** — no separate service. The model lives in
  `priv/tts/` (e.g. `model.onnx`) and is shipped with the release; point
  `SOUNDAI_TTS_MODEL_PATH` elsewhere to override. When the file is absent the
  `OrtexServer` is not started and `/api/tts` reports `503`, so the feature is
  safely off until the model is deployed.

## 12. Gotchas & conventions

- **`hidden` attribute vs Tailwind `hidden` class**: JS toggles the attribute;
  never put the `hidden` class on JS-managed elements (see §4.1).
- **`process.env.NODE_ENV`** is defined by the esbuild build (dev vs prod);
  used in `app.js` to gate service-worker registration.
- **Keep `whisper_worker.js` at its stable URL**; the SW precache and the
  `new Worker()` call both depend on it.
- **COOP/COEP are required** for threaded WASM; keep `credentialless`.
- **Icons**: always the `<.icon name="hero-...">` component; it renders a
  `<span>` with `hero-*` classes (no SVG, no `id` attr support — wrap it if you
  need to target it).
- **Bump `CACHE_NAME`** in `service_worker.js` whenever the app shell changes,
  otherwise old assets may be served from the SW cache.
- Model/model-config changes live in `whisper_config.js` (JS), while the
  settings-page options live in `SettingsHTML` (`@models`); keep them in sync.
- TTS engine options live in `SettingsHTML` (`@tts_models`); the `tts_engine.js`
  registry is the JS counterpart. When a new engine class is added, register it
  in `tts_engine.js` and add the corresponding option to `@tts_models`.
- **Server TTS is optional and in-process**: config lives under
  `config :soundai, Soundai.TTS` (`model_path`, `max_text_length`; see
  `config/config.exs` and `config/runtime.exs`). The model file is checked at
  boot (`Soundai.TTS.enabled?/0`) — the `OrtexServer` GenServer is only started
  when it exists.
- **ONNX sessions are not safe for concurrent runs**: every synthesis goes
  through the single `Soundai.TTS.OrtexServer` GenServer (a FIFO queue), so
  requests are serialized. Do not call `Ortex.run/2` outside that process.
- `Soundai.TTS` is a thin seam with an injectable `:adapter` (tests use
  `TTSFakeAdapter`); keep synthesis behind it, never call `OrtexServer` from a
  controller directly.
- **Cookies / `fetch_cookies`**: the `:api` pipeline must include
  `plug :fetch_cookies` — both `TranscriptionController` and
  `ConversationAudioController` read `conn.cookies["soundai_conversation"]`.
  Body `conversation_id` takes precedence over the cookie; `reset: true`
  deletes the stored context and returns a fresh id.
- **LLM timeout budget**: every LLM call is bounded by `llm_timeout_ms`
  (default 30 s, `config :soundai, Soundai.Conversation`); a hang surfaces as
  `{:error, :llm_timeout}` → 504. The client adds its own 15 s fetch timeout
  and a speaking watchdog (T0011/T0015) so no wait is unbounded.
- **The `server` TTS engine now means the audio reply**: selecting "Servidor
  (respuesta de voz)" in `/settings` makes `voice_assistant.js` POST the
  transcript to `/api/conversations/audio` (LLM + server TTS in one call) and
  play the returned WAV — it does **not** call `ServerTTSEngine.speak/4`
  (legacy `/api/tts` path, kept only for interface compatibility). A 503 from
  the audio endpoint falls back to text mode for that utterance.
- **The LLM seam must never raise**: `Soundai.Conversation.submit_transcript/2`
  maps every expected failure to a stable reason (`:empty`, `:too_long`,
  `:invalid`, `:llm_unavailable`, `:llm_timeout`); controllers turn those into
  422/502/504 JSON. The client renders short Spanish quiet notes, never the
  error state.

## 13. TTS benchmarks (T0008)

Benchmark environment: Linux aarch64, Node.js v22.20.0, transformers.js ^4.2.0,
WASM only (WebGPU is unavailable in Node.js). Numbers are single cold-load runs
(not the 3-run median the ticket asks for). Fixed Spanish test text:
`"Buenos días. Hoy hace un día hermoso y soleado. ¿Qué planes tienes para el fin de semana?"`.

Scope note: WebGPU, cached loads, and memory footprint were **not** measured.
The removal decision does not hinge on them — the `speaker_embeddings`
interface break is environment-independent. Benchmark scripts are preserved in
`sdlc/tickets/done/` (`T0008_test_tts.mjs`, `T0008_supertonic_test.html`) so the
numbers can be reproduced or extended later.

| Metric | Xenova/mms-tts-spa | Supertonic-TTS-2-ONNX |
|---|---|---|
| Model download size | ~38 MB (fp32) | ~260 MB (fp32) |
| Cold load time | 8 251 ms | 25 943 ms |
| Primed synthesis latency | 1 725 ms | 1 677 ms |
| Synthesis ratio (audio duration / wall-clock) | 4.02x | 5.95x |
| Sampling rate | 16 000 Hz | 44 100 Hz |
| Engine-specific parameters | None | `speaker_embeddings` required |

**Decision: Supertonic-TTS-2-ONNX removed from available options.**

Reasons:
1. **Requires engine-specific `speaker_embeddings` parameter** — breaks the generic `synthesize(text)` interface in `tts_worker.js`. The current architecture calls `pipeline("text-to-speech", modelId)(text)` with no model-specific options; Supertonic throws without speaker embeddings.
2. **3.1x slower cold load** (26s vs 8s) — unacceptable for target users (older adults, possibly low-end hardware).
3. **7x larger download** (260 MB vs 38 MB) — significant barrier on mobile/limited connections.
4. **Voice files are Git LFS binaries** — additional complexity to load speaker embeddings in browser context.

Default engine remains `Xenova/mms-tts-spa`. That same model is what the
in-process Elixir server engine runs with Ortex/ONNX (`priv/tts/`), so these
numbers also characterize the server-side TTS backend (its latency being the
browser ↔ `/api/tts` round trip on top of the synthesis cost).