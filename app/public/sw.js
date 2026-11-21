// GesCo Bar : l'application s'ouvre même sans connexion (les données se synchronisent au retour du réseau).
const CACHE = "gesco-shell-v35";
const SHELL = ["./", "./index.html", "./manifest.webmanifest", "./icon.svg", "./icon-192.png", "./icon-512.png",
  "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.js", "https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.js"];
self.addEventListener("install", e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting())); });
self.addEventListener("activate", e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim())); });
self.addEventListener("fetch", e => {
  const u = new URL(e.request.url);
  const photo = u.pathname.startsWith("/storage/v1/object/public/produits/"); // photos des produits : gardées pour le hors-ligne
  if (e.request.method !== "GET" || (u.hostname.endsWith("supabase.co") && !photo)) return; // données : toujours le réseau
  if (u.pathname.startsWith("/console")) return; // console éditeur : jamais en cache
  if (u.origin === location.origin && /^\/(conditions|remboursement)/.test(u.pathname)) return; // pages légales : réseau direct
  if (e.request.mode === "navigate") {
    e.respondWith(fetch(e.request).then(r => { const c = r.clone(); caches.open(CACHE).then(x => x.put("./index.html", c)); return r; }).catch(() => caches.match("./index.html")));
    return;
  }
  e.respondWith(caches.match(e.request).then(hit => hit || fetch(e.request).then(r => {
    if (r.ok && (photo || u.origin === location.origin || u.hostname.includes("jsdelivr") || u.hostname.includes("fonts."))) { const c = r.clone(); caches.open(CACHE).then(x => x.put(e.request, c)); }
    return r;
  })));
});
