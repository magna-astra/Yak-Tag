// ============================================================
// YAK-TAG — service worker
//
// Lets the tap page (t.html), the owner page (cow.html) and the herder
// app (app/) open with no signal, so a scan or an entry can still be
// saved to the offline queue.
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

const VERSION = 'yt-shell-v2';

// = SUPABASE_URL / SUPABASE_KEY in config.js (the public key every page
// already carries). Change both places together.
const API = 'https://mjijgxfmkgtxmpbmshtl.supabase.co';
const PUBLIC_KEY = 'sb_publishable_npSJ3ZAWO_ODx_cXbvORoQ__t-_1GiJ';
const MAX_PUBLIC_AGE = 7 * 86400000;            // = offline.js; server takes 7 days back

const SHELL = [
  't.html', 'cow.html', 'config.js', 'offline.js',
  'assets/logo-256.png', 'assets/logo-64.png', 'assets/logo-180.png', 'assets/favicon.ico',
  // the herder app (installable, opens with no signal)
  'app/', 'app/index.html', 'app/manifest.json',
  'assets/app-icon-192.png', 'assets/app-icon-512.png'
];
const LIB = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.2/dist/umd/supabase.js';

const scope = self.registration.scope;                  // https://yaktag.org/
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

// ---------- background sending of no-signal taps (Android Chrome) ----------
// A stranger who tapped with no signal may close the browser before the
// signal returns. offline.js asks for a "sync"; the browser wakes this
// worker once the phone is online, even with the page closed, and the
// tap is sent from here — the same request the page makes, with the tap's
// own time and position. The server ignores a client_uuid it already has,
// so a page sending the same tap at the same moment cannot double it.
// Herders' entries need their login: the app pages send those, as before.
function queueDb(mode, fn) {
  return new Promise((resolve, reject) => {
    const r = indexedDB.open('yaktag-offline', 1);
    r.onupgradeneeded = () => r.result.createObjectStore('queue', { keyPath: 'id' });
    r.onerror = () => reject(r.error);
    r.onsuccess = () => {
      const t = r.result.transaction('queue', mode);
      const q = fn(t.objectStore('queue'));
      t.oncomplete = () => { r.result.close(); resolve(q && q.result); };
      t.onerror = t.onabort = () => { r.result.close(); reject(t.error); };
    };
  });
}
function postScan(body) {
  return fetch(API + '/rest/v1/rpc/record_public_scan', {
    method: 'POST',
    headers: { apikey: PUBLIC_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  });
}
async function sendQueuedScans() {
  const items = (await queueDb('readonly', s => s.getAll())) || [];
  for (const item of items) {
    if (item.kind !== 'public_scan') continue;
    if (Date.now() - item.created > MAX_PUBLIC_AGE) {      // too old for the server
      await queueDb('readwrite', s => s.delete(item.id));
      continue;
    }
    const p = item.payload, age = Date.now() - Date.parse(p.scanned_at);
    const body = {
      p_tag_code: p.tag_code, p_lat: p.lat, p_lng: p.lng, p_accuracy: p.accuracy,
      p_user_agent: p.user_agent, p_client_uuid: p.client_uuid, p_scanned_at: p.scanned_at,
      p_age_ms: Number.isFinite(age) && age >= 0 ? Math.round(age) : null
    };
    // a network error throws out of here: the browser retries the sync later
    let res = await postScan(body);
    if (res.status === 404) {                             // database before schema_v51
      delete body.p_age_ms;
      res = await postScan(body);
    }
    if (res.ok) await queueDb('readwrite', s => s.delete(item.id));
    // any other refusal stays for the page, which counts and reports it
  }
}
self.addEventListener('sync', event => {
  if (event.tag === 'yt-scans') event.waitUntil(sendQueuedScans());
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
  const path = url.origin + url.pathname;               // t.html?tag=… → t.html

  // Pinned library: the file at this exact version never changes. If it
  // could not be stored at install (no signal then), store it the first
  // time it loads — without it the pages can't open offline at all.
  if (req.url === LIB) {
    event.respondWith(caches.match(LIB).then(hit => hit || fetch(req).then(res => {
      if (res.ok) {
        const copy = res.clone();
        caches.open(VERSION).then(c => c.put(LIB, copy)).catch(() => {});
      }
      return res;
    })));
    return;
  }

  if (!shellUrls.has(path)) return;                     // not ours — untouched

  // Pages are kept under their path (one copy for every ?tag=). Scripts
  // are kept under their full address, ?v= included, so a slow network
  // never pairs a new page with an old config.js / offline.js. Another
  // version is used only when there is no network at all.
  const isPage = url.pathname.endsWith('.html') || url.pathname.endsWith('/');   // app/ = app/index.html
  const key = isPage ? path : req.url;

  event.respondWith((async () => {
    const cache = await caches.open(VERSION);
    const net = fetch(req).then(res => {
      if (res.ok) {
        cache.put(key, res.clone()).then(() => isPage ? null : cache.keys().then(keys => {
          // keep only the newest version of this script
          for (const k of keys) {
            const u = new URL(k.url);
            if (u.origin + u.pathname === path && k.url !== key) cache.delete(k);
          }
        })).catch(() => {});
      }
      return res;
    });
    net.catch(() => {});                                // handled below
    try {
      return await withTimeout(net, 4000);
    } catch (e) {
      const hit = await cache.match(key);
      if (hit) return hit;
      try {
        return await net;    // nothing stored for this version: wait for the slow network
      } catch (err) {
        const any = await cache.match(path, { ignoreSearch: true });
        if (any) return any; // no network at all: any stored version beats nothing
        throw err;
      }
    }
  })());
});
