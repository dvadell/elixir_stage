# Soundai — Technical Description

Voice-first speech-to-text web app: a single microphone button that transcribes
Spanish speech locally in the browser using **Whisper** via **Transformers.js**
(on WebGPU or WASM/CPU), shows the transcript on screen, and speaks the
server's echo of it aloud through a pluggable TTS engine: the native Web Speech
API (`speechSynthesis`), a local Transformers.js VITS worker, or the
**in-process Elixir TTS** (`POST /api/tts`), which runs the same VITS model with
ONNX Runtime via `Ortex`.

It is deliberately **offline-first and client-side**: there is **no Phoenix
LiveView / websocket** at runtime. The server only renders static HTML shells
and accepts two JSON endpoints; every interaction (mic capture, model load,
inference, UI state) happens in the browser. Once the page and the speech model
are cached, STT keeps working with no network at all. The transcribed **text**
is POSTed to the server as a best-effort call — STT never depends on it.

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

voice_assistant.js -> tts_engine.js (pluggable TTS engine registry)
  |--> native engine (speechSynthesis) -> speaker
  |--> transformers engine (local VITS model)
  |     |
  |     v
  |  tts_worker.js (Web Worker, Transformers.js + VITS)
  |     |--> WebGPU (preferred) --> WASM/CPU (fallback)
  |     v
  |  Float32Array audio @16 kHz
  |     v
  |  Web Audio API (AudioContext) -> speaker
  `--> server engine (Elixir /api/tts)
        |
        | POST /api/tts {text, language} (JSON, same origin)
        v
     SoundaiWeb.TTSController -> Soundai.TTS (Ortex/ONNX, VITS)
        |
        v
     audio/wav bytes (X-TTS-Duration-Ms, X-TTS-Model)
        |
        v
     AudioContext.decodeAudioData -> AudioBufferSourceNode -> speaker
```

Audio capture never leaves the browser. For TTS, only the assistant's **text**
is sent to the server (by the `server` engine); the synthesized audio returns
and is played locally. The Phoenix backend serves:

- HTML shells for `/` and `/settings`
- the built JS/CSS bundles
- `service_worker.js` (offline caching)

The backend also accepts two JSON calls:

```text
transcribed text
  |
  | POST /api/transcriptions  (fetch, JSON, same origin)
  v
SoundaiWeb.TranscriptionController -> Soundai.Conversation.submit_transcript/1
  |
  v
{"ok": true, "response": "Buenos días", "language": "spanish"}
  |
  v
Browser tts_engine.js -> selected engine -> speaker
  |
  |-- native / local (speechSynthesis / VITS worker): stays in the browser
  `-- server engine: POST /api/tts -> SoundaiWeb.TTSController -> speaker
```

`submit_transcript/1` validates the transcript and returns the trimmed text as
a `response` field in the JSON envelope. Today it echoes the transcript back;
the follow-up LLM relay (through Needle) replaces the echo with the LLM's
answer inside this same function. The client speaks the server's `response`
text aloud through the pluggable TTS engine (`tts_engine.js`), which can route
to the native Web Speech API, a local Transformers.js VITS worker, or the
in-process Elixir server engine (see §6 for how the selection is made).

Server-side TTS (`POST /api/tts`) is an **optional, in-process** feature: when a
model file is present it is synthesized inside `soundai` with Ortex; when it is
absent the endpoint reports `503` and the browser falls back to the native
engine. There is no standalone TTS service.

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
│   ├── conversation.ex            receives transcripts; seam for the future LLM relay
│   ├── mailer.ex
│   └── tts/
│       ├── tts.ex                 server-side TTS seam: synthesize/2 (Ortex)
│       ├── tts/ortex_server.ex    GenServer owning the ONNX session (serialized calls)
│       ├── tts/vits_tokenizer.ex  char-level tokenizer mirroring HF VitsTokenizer
│       └── tts/wav.ex             Float32 waveform -> 16 kHz PCM WAV encoder
├── lib/soundai_web/
│   ├── router.ex                   get "/", get "/settings", post /api/transcriptions, /api/tts
│   ├── endpoint.ex                 COOP/COEP headers, static serving, no /live socket
│   ├── controllers/
│   │   ├── home_controller.ex      renders the voice assistant shell
│   │   ├── home_html/              home page templates (HTML module)
│   │   ├── settings_controller.ex  renders the STT + TTS settings shell
│   │   ├── settings_html/          settings templates
│   │   ├── transcription_controller.ex  POST /api/transcriptions JSON endpoint
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
├── sdlc/tickets/                   active tickets (T0011.md)
│   └── done/                       implemented tickets T0002.md–T0010.md
└── test/
    ├── soundai/                    TTS unit tests (tts, vits_tokenizer, wav)
    ├── soundai_web/controllers/    controller tests (home, settings, transcriptions, tts)
    └── support/tts_fake_adapter.ex test adapter injected into Soundai.TTS
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
| `POST /api/transcriptions` | `TranscriptionController.create` | JSON envelope `{"ok": true, "response": <text>, "language": ...}` (no template) |
| `POST /api/tts`  | `TTSController.create`     | `audio/wav` bytes + `X-TTS-Duration-Ms` / `X-TTS-Model` headers (no template) |

`service_worker.js` is a static file served from `priv/static/` (added to
`SoundaiWeb.static_paths/0`). `Plug.Static` `only:` includes it.

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
| `#voice-send-status`  | non-blocking "Sending…"/offline note under the transcript |

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
- On a transcription result, `sendTranscript/1` POSTs `{text, language}` to
  `/api/transcriptions` with `fetch` while the UI shows the "Sending…" state.
  The send is best-effort: on success the note disappears; on failure the
  transcript stays visible under a quiet "offline / couldn't reach the server"
  note and the UI never enters the error state. When `navigator.onLine` is
  false the POST is skipped entirely.
- On a successful send, the server returns `{"ok": true, "response": "...", "language": "..."}`
  echoing the transcript. The client speaks the `response` text aloud through
  the configured TTS engine (`tts_engine.js` — native `speechSynthesis`, a
  local VITS worker, or the server engine calling `/api/tts`), entering the
  `speaking` state ("Speaking…"). The engine's `onend` event transitions back
  to `result`.
- Starting a new recording (`pointerdown`) calls `ttsEngine.cancel()` so the
  user can interrupt the assistant mid-speech.

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