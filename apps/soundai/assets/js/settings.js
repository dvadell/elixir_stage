// Client-side controller for the /settings page.
//
// The STT model preference is read from and written to a browser cookie
// entirely here, with no server round-trip. This mirrors the voice assistant's
// offline-first design: the settings page works even when the network is
// unavailable (as long as the app shell is cached).

const STORAGE_KEY = "soundai_model";

export function mountSTTSettings() {
  const select = document.getElementById("stt-model");
  if (!select || select.dataset.sttMounted) return;
  select.dataset.sttMounted = "true";

  const desc = document.getElementById("stt-model-desc");
  const saved = document.getElementById("stt-saved");
  const savedText = document.getElementById("stt-saved-text");

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
    document.cookie = `${name}=${encodeURIComponent(value)}; path=/; max-age=31536000; SameSite=Lax`;
  }

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
    savedText.textContent = `Saved: ${option.dataset.label || option.value} will be used next time the voice assistant loads.`;
    saved.hidden = false;
  }

  const stored = readCookie(STORAGE_KEY);
  if (stored && [...select.options].some((opt) => opt.value === stored)) {
    select.value = stored;
  }

  showDescription();

  select.addEventListener("change", (event) => {
    writeCookie(STORAGE_KEY, event.target.value);
    showDescription();
    showSaved();
  });
}