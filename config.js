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
// OPTIONAL: Google Maps satellite key.
//
// Leave EMPTY and the map uses Sentinel-2 satellite imagery (ESA
// open data via EOX) — free forever, no key, no quota, licensed
// for commercial use. Resolution is ~10m: enough to read terrain,
// rivers and grazing ground, not enough to see an individual animal.
//
// Set a key here to ADD a Google satellite layer to the switcher
// for sharper imagery.
//
// COST (verified 2026): Google scrapped the old $200/month credit
// in March 2025. Dynamic Maps now gives 10,000 free map loads per
// month, then $7 per 1,000. One "load" = one user opening the map
// tab. A billing account with a card is required even to use the
// free tier.
//   ~6,000 loads/month  -> $0
//   ~30,000 loads/month -> ~$140/month
//   ~120,000            -> ~$770/month
// Always restrict the key to your domain (HTTP referrers) or
// someone else can run up your bill.
// ============================================================
const GOOGLE_MAPS_KEY = '';

// ============================================================
// OPTIONAL: Mapbox token for high-resolution satellite.
//
// Free tier: 50,000 map loads/month, no credit card to start,
// commercial use allowed. Sign up at mapbox.com, copy the default
// public token (starts pk.), paste it here. It adds a
// "Нарийвчилсан хиймэл дагуул" option to the layer switcher with
// sub-meter imagery in many areas.
//
// Leave empty and the map uses free Sentinel-2 only.
// Restrict the token to your domain in the Mapbox dashboard.
// ============================================================
const MAPBOX_TOKEN = '';

// ============================================================
// ⚠️  TESTING ONLY — REMOVE BEFORE COMMERCIAL LAUNCH
//
// Loads Google's satellite tiles directly from mt1.google.com.
// No key, no billing, unlimited zoom, best imagery available.
//
// THE CATCH: Google's Terms of Service require their tiles be
// served through the Maps JavaScript API. Pulling them from the
// tile endpoint is undocumented and unlicensed. It works today.
// It can stop working any day, without notice, and using it in a
// product you charge for is a licensing exposure.
//
// Acceptable while you are testing on a github.io domain with
// five tags. Set this to false and configure MAPBOX_TOKEN above
// before you take money from a customer.
//
// When the layer is active the map shows a visible warning badge,
// so nobody demos this to an investor without noticing.
// ============================================================
const USE_GOOGLE_TILES_TESTING = true;

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
