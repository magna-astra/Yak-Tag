# YAK-TAG — livestock digital ID

Mongolian livestock identification, registration and encounter history.

**The NFC tag identifies the animal. The phone that taps it provides the GPS.**
The tag has no battery and no GPS.

Live at **https://yaktag.org/** (GitHub Pages). Database, logins and photos:
Supabase. Alerts: Telegram (free). Everything runs on free tiers.

For the full working notes — rules, what was done when, what to do next —
read [`NEXT_SESSION.md`](NEXT_SESSION.md).

---

## What's where

```
index.html how.html faq.html order.html   public website (assets/style-a.css)
t.html                    public tap page — what a phone opens from a tag
cow.html                  owner / herder page for one animal (works offline)
admin/index.html          dashboard (farms, animals, tags, users, map, reports)
config.js offline.js sw.js  shared code: Supabase client, offline queue, offline cache
db/schema.sql             original database; db/schema_v3 … v46 = every change since,
                          run in number order in Supabase → SQL Editor
supabase/functions/       admin-users Edge Function (creates logins)
tools/nfc_tag.py          writes and password-protects NFC tags (ACR1552U + NTAG215)
scripts/export_supabase.py  table export used by the daily backup
.github/workflows/
  backup.yml              daily backup → private repo magna-astra/Yak-Tag-backups
  keepalive.yml           keeps the free Supabase project from pausing
_config.yml               keeps notes, SQL and tools off the published website
```

This repo is **public** (GitHub Pages needs that on the free plan). It holds
no secrets: the Supabase key in `config.js` is the publishable key, and all
access control is Row Level Security in the database. Real data and backups
never go in this repo.

## Repo secrets (Settings → Secrets and variables → Actions)

| Secret | Used by | Where to find it |
|---|---|---|
| `SUPABASE_URL` | both workflows | Supabase → Project Settings → API |
| `SUPABASE_ANON_KEY` | keepalive | same page (publishable key) |
| `SUPABASE_SERVICE_KEY` | both workflows | same page (secret key — never in code) |
| `BACKUP_TOKEN` | backup | GitHub fine-grained token, Contents read/write on `Yak-Tag-backups` only — has an expiry date |
| `SUPABASE_DB_URL` | backup (optional) | Supabase → Connect → Session pooler URI with the database password — turns on the full `database.dump` copy |

## Free-tier limits to watch

| Limit | Value | Notes |
|---|---|---|
| Database | 500 MB | 12,000 animals ≈ 120 MB |
| File storage | 1 GB | photos are shrunk to ~0.3 MB before upload |
| Inactivity pause | 7 days | handled by `keepalive.yml` |
| Supabase backups | none on free | handled by `backup.yml` (daily) |
| Scheduled workflows | switched off after 60 days without a commit | `keepalive.yml` re-enables them on every run |

## Tag technology

| Layer | Range | Reader | Status |
|---|---|---|---|
| NFC — NTAG215 | ~4 cm | phone built-in | active |
| QR code (printed) | 3–8 m | any phone camera | active |
| UHF — EPC Gen2 | 1–3 m | external reader | reserved (`tags.uhf_epc`) |

## Notes

- Read distance depends on tag design, reader power, antenna placement,
  animal position and field conditions. No fixed distance is guaranteed.
- Figures and photos on the marketing site are examples, not real
  customer deployments.
- Every animal's registration includes a **muzzle photo**. A muzzle print is
  unique like a fingerprint; this dataset cannot be created retroactively.
