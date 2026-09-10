# YAK-TAG — Livestock digital ID platform

Mongolian cattle identification, registration and encounter-history system.

**RFID/NFC identifies the animal. The herder's phone provides the GPS.**
The tag contains no battery and no GPS.

---

## Repo layout

```
index.html                      marketing site (GitHub Pages serves this)
db/schema.sql                   database — run this first
db/seed.sql                     test data — run this second
admin/                          admin dashboard (Step 2, in progress)
assets/                         images, QR sheets
.github/workflows/
  keepalive.yml                 stops the Supabase free project pausing
  backup.yml                    weekly database dump
```

---

## Setup

### 1. Push this repo
Open GitHub Desktop → **Add Local Repository** → choose this folder →
**Publish repository**.

> Keep it **private** if you enable `backup.yml`. Backups contain real data.

### 2. Turn on GitHub Pages
Repo → **Settings → Pages** → Source: `main`, folder `/ (root)` → Save.
Your site appears at `https://<username>.github.io/<repo>/`.

### 3. Create the Supabase project
1. supabase.com → New project (free tier)
2. **SQL Editor** → paste all of `db/schema.sql` → Run
3. **Authentication → Users** → create the 5 test users listed at the top
   of `db/seed.sql`
4. Copy their UUIDs into the top of `db/seed.sql`
5. **SQL Editor** → paste `db/seed.sql` → Run

### 4. Verify the farm isolation actually works

This is the most important test in the project. Run it before building
anything on top.

| Logged in as | `select count(*) from cattle;` | Meaning |
|---|---|---|
| `admin12@yaktag.test` | **50** | correct — sees only Farm 12 |
| `admin07@yaktag.test` | **10** | correct — sees only Farm 7 |
| `super@yaktag.test` | **60** | correct — sees everything |

If a farm admin sees 60, RLS is not enabled. Stop and fix it.

Also confirm overlapping tag ranges are rejected — the test SQL is at the
bottom of `seed.sql`. It **must** fail.

### 5. Add repo secrets
Repo → **Settings → Secrets and variables → Actions**:

| Secret | Where to find it |
|---|---|
| `SUPABASE_URL` | Supabase → Project Settings → API |
| `SUPABASE_ANON_KEY` | same page |
| `SUPABASE_DB_URL` | Project Settings → Database → Connection string (URI) |

Then run **Keep Supabase awake** once manually from the Actions tab to
confirm it returns HTTP 200.

---

## Free-tier limits to watch

| Limit | Value | Notes |
|---|---|---|
| Database | 500 MB | 12,000 cattle ≈ 120 MB |
| File storage | 1 GB | **don't put photos here** — use Cloudflare R2 |
| Inactivity pause | 7 days | handled by `keepalive.yml` |
| Backups | none | handled by `backup.yml` |
| Projects | 2 | one dev, one prod |

---

## Tag technology

| Layer | Range | Reader | Status |
|---|---|---|---|
| QR code (printed) | 3–8 m | any phone camera | active |
| NFC — NTAG215 | ~4 cm | phone built-in | active |
| UHF — EPC Gen2 | 1–3 m | external reader | reserved (`tags.uhf_epc`) |

Adding UHF later fills in an existing column. It is not a migration.

---

## Build progress

- [x] Marketing site (Mongolian)
- [x] Database schema + RLS
- [x] Seed data
- [ ] Admin dashboard — **Step 2**
- [ ] Tag + QR generator — Step 3
- [ ] Herder PWA (register, camera, GPS, offline sync) — Step 4
- [ ] Field test, 10–20 animals — Step 5

---

## Notes

- Actual read distance depends on tag design, reader power, antenna
  placement, animal position and field conditions. No fixed distance is
  guaranteed.
- All figures shown on the marketing site are example data, not real
  customer deployments.
- Every cow's registration includes a **muzzle photo**. A muzzle print is
  unique like a fingerprint; this dataset cannot be created retroactively.
