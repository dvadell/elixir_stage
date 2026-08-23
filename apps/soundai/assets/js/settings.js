// Client-side controller for the /settings page.
//
// The STT model and TTS engine preferences are read from and written to
// browser cookies entirely here, with no server round-trip. This mirrors
// the voice assistant's offline-first design: the settings page works even
// when the network is unavailable (as long as the app shell is cached).

const STORAGE_KEY_STT = "soundai_model";
const STORAGE_KEY_TTS = "soundai_tts";

// ---------------------------------------------------------------------------
// Shared cookie helpers
// ---------------------------------------------------------------------------

function readCookie(name) {
  const prefix = `${name}=`;
  for (const cookie of document.cookie.split("; ")) {
    if (cookie.startsWith(prefix)) {
      return decodeURIComponent(cookie.slice(prefix.length));
    }
  }
  return null;
}

function writeCookie(name, value) {
  const secure = location.protocol === "https:" ? "; Secure" : "";
  document.cookie = `${name}=${encodeURIComponent(value)}; path=/; max-age=31536000; SameSite=Lax${secure}`;
}

// ---------------------------------------------------------------------------
// Generic select mounter — handles one <select> + description + saved banner
// ---------------------------------------------------------------------------

function mountSelect(settings) {
  const { selectId, descId, savedId, savedTextId, cookieKey, mountedKey } = settings;
  const select = document.getElementById(selectId);
  if (!select || select.dataset[mountedKey]) return;
  select.dataset[mountedKey] = "true";

  const desc = document.getElementById(descId);
  const saved = document.getElementById(savedId);
  const savedText = document.getElementById(savedTextId);

  function selectedOption() {
    return select.options[select.selectedIndex];
  }

  function showDescription() {
    const option = selectedOption();
    if (!option) return;
    desc.textContent = option.dataset.desc || "";
    desc.hidden = !desc.textContent;
  }

  function showSaved() {
    const option = selectedOption();
    if (!option) return;
    savedText.textContent = `Guardado: ${option.dataset.label || option.value} se usará la próxima vez que abras el asistente de voz.`;
    saved.hidden = false;
  }

  const stored = readCookie(cookieKey);
  if (stored && [...select.options].some((opt) => opt.value === stored)) {
    select.value = stored;
  }

  showDescription();

  select.addEventListener("change", (event) => {
    writeCookie(cookieKey, event.target.value);
    showDescription();
    showSaved();
  });
}

// ---------------------------------------------------------------------------
// Public entry points
// ---------------------------------------------------------------------------

export function mountSTTSettings() {
  mountSelect({
    selectId: "stt-model",
    descId: "stt-model-desc",
    savedId: "stt-saved",
    savedTextId: "stt-saved-text",
    cookieKey: STORAGE_KEY_STT,
    mountedKey: "sttMounted",
  });
}

export function mountTTSSettings() {
  mountSelect({
    selectId: "tts-model",
    descId: "tts-model-desc",
    savedId: "tts-saved",
    savedTextId: "tts-saved-text",
    cookieKey: STORAGE_KEY_TTS,
    mountedKey: "ttsMounted",
  });
}
