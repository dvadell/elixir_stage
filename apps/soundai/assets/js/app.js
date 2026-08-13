// Soundai is a fully client-side, offline-first voice assistant.
//
// The pages are rendered as plain HTML by Phoenix and driven entirely from the
// browser: there is no Phoenix LiveView connection and no websocket, so losing
// the network never freezes the UI. The Whisper model (speech-to-text) runs
// locally in a Web Worker via Transformers.js, and a service worker caches the
// app shell so the pages reload even with no wifi once they have been visited.

import "phoenix_html"

import {mountVoiceAssistant} from "./voice_assistant"
import {mountSTTSettings} from "./settings"

function boot() {
  mountVoiceAssistant()
  mountSTTSettings()
}

// The theme toggle and offline banner are plain client-side behaviors.
function initThemeToggle() {
  document.addEventListener("click", (event) => {
    const button = event.target.closest("[data-phx-theme]")
    if (!button) return
    // Dispatch on the button so it bubbles to window, matching the listener in
    // the root layout (which reads `event.target.dataset.phxTheme`).
    button.dispatchEvent(new CustomEvent("phx:set-theme", {bubbles: true}))
  })
}

function initOfflineBanner() {
  const banner = document.getElementById("offline-banner")
  if (!banner) return

  const update = () => {
    banner.hidden = navigator.onLine
  }
  window.addEventListener("online", update)
  window.addEventListener("offline", update)
  update()
}

// A small service worker caches the app shell (HTML, CSS, JS and the Whisper
// worker) so the pages load without a connection after the first visit. The
// Whisper model itself is cached by Transformers.js in the browser's Cache
// Storage, which is what makes speech recognition fully offline.
function initServiceWorker() {
  if (process.env.NODE_ENV === "production" && "serviceWorker" in navigator) {
    navigator.serviceWorker.register("/service_worker.js").catch((err) => {
      console.warn("[soundai] service worker registration failed:", err)
    })
  }
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => {
    boot()
    initThemeToggle()
    initOfflineBanner()
    initServiceWorker()
  })
} else {
  boot()
  initThemeToggle()
  initOfflineBanner()
  initServiceWorker()
}