// ============================================================
// YAK-TAG — shared Supabase config
// Used by admin/index.html and cow.html
//
// This key is the PUBLISHABLE key. It is safe in public code:
// it respects Row Level Security, so a farm admin still only
// sees their own farm. Never put the sb_secret_... key here.
// ============================================================

const SUPABASE_URL = 'https://oxfbxqclqfglpzgzizhq.supabase.co';
const SUPABASE_KEY = 'sb_publishable_W3WMWLP28Czb2_5VTDQUlg_--3vfY71';

// ============================================================
// Google Maps API key.
//
// Get one at: console.cloud.google.com -> APIs & Services ->
// Credentials. Enable "Maps JavaScript API". Google gives a
// $200/month credit, which covers roughly 28,000 map loads —
// far more than a pilot will use.
//
// IMPORTANT: restrict the key to your domain (HTTP referrers:
// magna-astra.github.io/*) or anyone can run up your quota.
//
// Leave this empty and the map falls back to OpenStreetMap,
// which works without a key but has almost no detail in rural
// Mongolia.
// ============================================================
const GOOGLE_MAPS_KEY = '';

const sb = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

// ---------- shared helpers ----------

async function requireLogin(redirectTo = 'index.html') {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) {
    window.location.href = redirectTo;
    return null;
  }
  return session;
}

async function myProfile() {
  const { data: { user } } = await sb.auth.getUser();
  if (!user) return null;
  const { data } = await sb
    .from('profiles')
    .select('id, full_name, role, farm_id')
    .eq('id', user.id)
    .single();
  return data;
}

function fmtDate(ts) {
  if (!ts) return '—';
  const d = new Date(ts);
  return d.toLocaleDateString('mn-MN', { month: 'short', day: 'numeric' });
}

function fmtDateTime(ts) {
  if (!ts) return '—';
  const d = new Date(ts);
  return d.toLocaleString('mn-MN', {
    month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit'
  });
}

function daysUntil(dateStr) {
  if (!dateStr) return null;
  const diff = new Date(dateStr) - new Date();
  return Math.ceil(diff / 86400000);
}
