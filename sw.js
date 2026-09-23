/* Shop Floor — lets the app open with no Wi-Fi.
   Pages: fetched fresh when there's a connection (so updates arrive), the
   saved copy when there isn't. Library, fonts and icons: saved copy first.
   Database requests are never touched — the app handles those itself. */
const SHELL = "shop-floor-shell-v1";
const FILES = ["./", "./index.html", "./manifest.webmanifest", "./icon-192.png", "./icon-512.png"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(SHELL).then((c) => c.addAll(FILES)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys()
    .then((keys) => Promise.all(keys.filter((k) => k.startsWith("shop-floor-shell-") && k !== SHELL).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener("fetch", (e) => {
  if (e.request.method !== "GET") return;
  const url = new URL(e.request.url);
  if (url.hostname.endsWith(".supabase.co")) return;          // live data: leave it alone

  const isPage = url.origin === self.location.origin &&
                 (e.request.mode === "navigate" || url.pathname.endsWith(".html") || url.pathname.endsWith("/"));
  if (isPage) {
    e.respondWith(fetch(e.request)
      .then((r) => { const copy = r.clone(); caches.open(SHELL).then((c) => c.put(e.request, copy)); return r; })
      .catch(() => caches.match(e.request).then((hit) => hit || caches.match("./index.html"))));
    return;
  }
  e.respondWith(caches.match(e.request).then((hit) => hit || fetch(e.request).then((r) => {
    if (r.ok || r.type === "opaque") { const copy = r.clone(); caches.open(SHELL).then((c) => c.put(e.request, copy)); }
    return r;
  })));
});
