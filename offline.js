// ============================================================
// YAK-TAG — offline scan queue
// Used by t.html and cow.html, after config.js.
//
// In the countryside a tap often happens with no signal. The scan
// (tag, GPS, time) is stored on the phone first and sent when the
// network is back — on the next page open, when the phone comes
// online, or every 30 s while a page is open.
//
// Every item carries a client_uuid made on the phone. The server
// ignores a uuid it already has, so a retry after a dropped
// connection can never create a second scan.
//
// Only scans are queued. Milk, feeding and photos still need a
// connection at the moment of saving.
// ============================================================

// crypto.randomUUID is missing on Android Chrome before v92 — common
// on older phones in the field. Same format, built by hand.
function ytUuid() {
  if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
  const b = crypto.getRandomValues(new Uint8Array(16));
  b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
  const h = [...b].map(x => x.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0,8)}-${h.slice(8,12)}-${h.slice(12,16)}-${h.slice(16,20)}-${h.slice(20)}`;
}

const ytQueue = (() => {
  const DB = 'yaktag-offline', STORE = 'queue';
  const MAX_PUBLIC_AGE = 7 * 86400000;   // server only accepts 7 days back
  const MAX_SERVER_FAILS = 10;           // rejected this often → give up on it
  let dbp = null, flushing = null, listeners = [];
  let stoppedOffline = false;            // last flush ended for lack of network

  function db() {
    if (!dbp) dbp = new Promise((resolve, reject) => {
      const r = indexedDB.open(DB, 1);
      r.onupgradeneeded = () => r.result.createObjectStore(STORE, { keyPath: 'id' });
      r.onsuccess = () => resolve(r.result);
      r.onerror = () => reject(r.error);
    });
    return dbp;
  }
  async function run(mode, fn) {
    const d = await db();
    return new Promise((resolve, reject) => {
      const t = d.transaction(STORE, mode);
      const req = fn(t.objectStore(STORE));
      t.oncomplete = () => resolve(req && req.result);
      t.onerror = () => reject(t.error);
    });
  }
  const put = item => run('readwrite', s => s.put(item));
  const del = id   => run('readwrite', s => s.delete(id));
  const all = ()   => run('readonly',  s => s.getAll());

  // No signal, DNS failure, timeout — worth retrying later.
  function isNetworkError(error) {
    if (!navigator.onLine) return true;
    const m = String((error && (error.message || error.details)) || error || '');
    return /fetch|network|load failed|timeout|abort/i.test(m);
  }

  // ---------- how each kind of item is sent ----------
  const senders = {
    // Public tap page → record_public_scan (anonymous).
    async public_scan(p) {
      const args = {
        p_tag_code: p.tag_code, p_lat: p.lat, p_lng: p.lng,
        p_accuracy: p.accuracy, p_user_agent: p.user_agent,
        p_client_uuid: p.client_uuid, p_scanned_at: p.scanned_at
      };
      let { data, error } = await sb.rpc('record_public_scan', args);
      // Database not yet on schema_v23: send the old way so scans keep
      // working. The time recorded is then the time it arrives.
      if (error && (error.code === 'PGRST202' || /function .*does not exist|Could not find the function/i.test(error.message))) {
        delete args.p_client_uuid; delete args.p_scanned_at;
        ({ data, error } = await sb.rpc('record_public_scan', args));
      }
      return { data, error };
    },

    // Owner page → scan_events (signed in). client_uuid is unique there,
    // so "already exists" means an earlier attempt did arrive.
    async app_scan(p, item) {
      const row = { ...p, was_offline: Date.now() - item.created > 120000 };
      const { error } = await sb.from('scan_events').insert(row);
      if (error && error.code === '23505') return { data: null, error: null };
      return { data: null, error };
    },

    // Milk: one row per cow per day, so sending it twice is harmless.
    // yield_date is the day it was entered on the phone, not the day
    // it reaches the server.
    async milk(p) {
      const { error } = await sb.from('milk_yield').upsert(p, { onConflict: 'cattle_id,yield_date' });
      return { data: null, error };
    },

    // Pregnancy / calving entry. p_client_uuid makes a resend return the
    // entry the server already has (schema_v31).
    async repro(p) {
      let { data, error } = await sb.rpc('record_repro_event', p);
      if (error && (error.code === 'PGRST202' || /Could not find the function/i.test(error.message))) {
        const q = { ...p }; delete q.p_client_uuid;          // database not yet on v31
        ({ data, error } = await sb.rpc('record_repro_event', q));
      }
      return { data, error };
    }
  };

  function notify() {
    count().then(n => listeners.forEach(fn => { try { fn(n); } catch (e) {} }))
           .catch(() => {});
  }

  async function flushOnce() {
    let items;
    stoppedOffline = false;
    try { items = await all(); } catch (e) { return; }
    items.sort((a, b) => a.created - b.created);
    for (const item of items) {
      if (item.kind === 'public_scan' && Date.now() - item.created > MAX_PUBLIC_AGE) {
        await del(item.id);                    // too old for the server to date correctly
        continue;
      }
      const send = senders[item.kind];
      // Unknown kind: this copy of offline.js is older than the page that
      // queued it (e.g. a cached file right after a deploy). Keep it —
      // a newer version will send it. Never throw an entry away.
      if (!send) continue;
      let res;
      try { res = await send(item.payload, item); }
      catch (e) { res = { error: e }; }
      if (!res.error) {
        await del(item.id);
        item.result = res.data;
        item.sent = true;
      } else if (isNetworkError(res.error)) {
        stoppedOffline = true;
        break;                                  // still offline — try again later
      } else {
        item.fails = (item.fails || 0) + 1;
        item.lastError = res.error;
        console.warn('Queued entry rejected:', item.kind, res.error);
        if (item.fails >= MAX_SERVER_FAILS) {
          await del(item.id);
          // Never lose an entry silently: remember it so the page can
          // tell the herder what did not get saved, and why.
          try {
            const list = JSON.parse(localStorage.getItem('yt-rejected') || '[]');
            list.push({ kind: item.kind, created: item.created, payload: item.payload,
                        error: String((res.error && res.error.message) || res.error) });
            localStorage.setItem('yt-rejected', JSON.stringify(list.slice(-50)));
          } catch (e) {}
        } else await put(item);
      }
    }
    return items;
  }

  // One flush at a time; callers share the running one.
  function flush() {
    if (!flushing) {
      flushing = flushOnce().finally(() => { flushing = null; notify(); });
    }
    return flushing;
  }

  async function count() {
    try { return (await all()).length; } catch (e) { return 0; }
  }

  // Store first, then try to send straight away.
  // Resolves to { sent, queued, result }.
  async function add(kind, payload) {
    const item = {
      id: ytUuid(),
      kind, payload, created: Date.now(), fails: 0
    };
    try {
      await put(item);
    } catch (e) {
      // Storage unavailable (private mode): send directly, as before.
      const res = await senders[kind](payload, item).catch(err => ({ error: err }));
      return { sent: !res.error, queued: false, result: res.data, error: res.error };
    }
    if (flushing) await flushing;              // don't race a running flush
    const done = await flush();
    const mine = (done || []).find(i => i.id === item.id);
    const sent = !!(mine && mine.sent);
    // queued = waiting for signal. Not sent AND not queued = the
    // server refused it (e.g. unknown tag); retried a few times anyway.
    return { sent, queued: !sent && (stoppedOffline || !navigator.onLine),
             result: mine && mine.result, error: mine && mine.lastError };
  }

  function onChange(fn) { listeners.push(fn); notify(); }

  window.addEventListener('online', flush);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') flush();
  });
  setInterval(() => { count().then(n => { if (n) flush(); }); }, 30000);
  setTimeout(flush, 1500);                     // anything left from last time

  return { add, flush, count, onChange };
})();

// Keeps t.html and cow.html openable with no signal. Only those pages
// and their own files are cached — the admin dashboard, the map and
// all database calls are never touched by it (see sw.js).
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('sw.js').catch(e => console.warn('SW:', e));
  });
}
