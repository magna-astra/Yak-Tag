// ============================================================
// YAK-TAG — service worker
//
// Lets the tap page (t.html) and the owner page (cow.html) open with
// no signal, so a scan can still be saved to the offline queue.
//
// It answers ONLY for the files listed in SHELL / LIB below. Every
// other request — admin dashboard, map tiles, Supabase database and
// storage calls — is not intercepted at all and behaves exactly as
// if this file did not exist.
//
// Pages are network-first: with signal you always get the latest
// version; the cached copy is used only when the network fails or
// takes longer than 4 seconds.
//
// To ship a change to the cached files, just deploy — pages refresh
// themselves on the next online visit. Bump VERSION only to force
// old caches to be deleted.
// ============================================================

const VERSION = 'yt-shell-v1';

const SHELL = [
  't.html', 'cow.html', 'config.js', 'offline.js',
  'assets/logo-256.png', 'assets/logo-64.png', 'assets/logo-180.png', 'assets/favicon.ico'
];
const LIB = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.2/dist/umd/supabase.js';

const scope = self.registration.scope;                  // …/Yak-Tag/
const shellUrls = new Set(SHELL.map(p => new URL(p, scope).href));

self.addEventListener('install', event => {
  event.waitUntil((async () => {
    const cache = await caches.open(VERSION);
    // One by one: a single missing file must not block the rest.
    await Promise.all([...shellUrls].map(u =>
      cache.add(new Request(u, { cache: 'reload' })).catch(() => {})));
    await cache.add(new Request(LIB, { mode: 'cors' })).catch(() => {});
    self.skipWaiting();
  })());
});

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    for (const key of await caches.keys()) {
      if (key.startsWith('yt-shell-') && key !== VERSION) await caches.delete(key);
    }
    await self.clients.claim();
  })());
});

function withTimeout(promise, ms) {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error('timeout')), ms);
    promise.then(v => { clearTimeout(t); resolve(v); },
                 e => { clearTimeout(t); reject(e); });
  });
}

self.addEventListener('fetch', event => {
  const req = event.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);
  const key = url.origin + url.pathname;                // t.html?tag=… → t.html

  // Pinned library: the file at this exact version never changes.
  if (req.url === LIB) {
    event.respondWith(caches.match(LIB).then(hit => hit || fetch(req)));
    return;
  }

  if (!shellUrls.has(key)) return;                      // not ours — untouched

  event.respondWith((async () => {
    const cache = await caches.open(VERSION);
    const net = fetch(req).then(res => {
      if (res.ok) cache.put(key, res.clone());
      return res;
    });
    try {
      return await withTimeout(net, 4000);
    } catch (e) {
      const hit = await cache.match(key);
      if (hit) return hit;
      return net;            // nothing cached (first visit): wait for the slow network
    }
  })());
});
