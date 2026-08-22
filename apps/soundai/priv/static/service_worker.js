// Offline-first service worker for Soundai.
//
// Caches the app shell (HTML pages, CSS/JS bundles, the Whisper worker and
// images) so the voice assistant can be reloaded and used without a network
// connection once it has been visited. The Whisper speech model itself is
// cached separately by Transformers.js in the browser's Cache Storage, so no
// model requests are handled here (cross-origin requests are ignored).

const CACHE_NAME = "soundai-shell-v3";

// Stable URLs that do not change between deployments. Digested assets
// (app-<hash>.js etc.) are cached at runtime with stale-while-revalidate.
const APP_SHELL = ["/assets/js/whisper_worker.js", "/assets/js/tts_worker.js", "/images/logo.svg", "/favicon.ico"];
const NAV_PATHS = ["/", "/settings"];

self.addEventListener("install", (event) => {
  event.waitUntil(
    (async () => {
      const cache = await caches.open(CACHE_NAME);
      await Promise.allSettled(APP_SHELL.map((url) => cache.add(url)));
      // Best effort: cache the pages too, so the first offline load works even
      // if the worker never got to cache a navigation response.
      await Promise.allSettled(NAV_PATHS.map((url) => cache.add(url)));
      await self.skipWaiting();
    })(),
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    (async () => {
      const keys = await caches.keys();
      await Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key)));
      await self.clients.claim();
    })(),
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  const url = new URL(request.url);

  if (request.method !== "GET") return;
  // Never intercept cross-origin requests: the Whisper model and WASM runtime
  // are cached by Transformers.js itself via the Cache Storage API.
  if (url.origin !== self.location.origin) return;

  if (request.mode === "navigate") {
    event.respondWith(networkFirst(request));
    return;
  }

  event.respondWith(staleWhileRevalidate(request));
});

async function networkFirst(request) {
  const cache = await caches.open(CACHE_NAME);
  try {
    const response = await fetch(request);
    if (response.ok) cache.put(request, response.clone());
    return response;
  } catch (_err) {
    const cached = await cache.match(request);
    if (cached) return cached;
    // Fall back to the cached home page for any navigation that is not cached.
    const home = await cache.match("/");
    if (home) return home;
    throw new Error("No cached response available for " + request.url);
  }
}

async function staleWhileRevalidate(request) {
  const cache = await caches.open(CACHE_NAME);
  const cached = await cache.match(request);
  const network = fetch(request)
    .then((response) => {
      if (response.ok) cache.put(request, response.clone());
      return response;
    })
    .catch(() => cached);
  return cached || network;
}