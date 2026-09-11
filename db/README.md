# Database patches — run in this order

Apply each once, in Supabase SQL Editor, with the role set to `postgres`.

| # | File | What it does |
|---|---|---|
| — | `schema.sql` | Base tables, RLS, triggers (original repo) |
| — | `seed.sql` | Test data — 3 farms, 5 users, 60 cattle |
| v3 | `schema_v3_rls_fix.sql` | **Critical.** Views were bypassing RLS. Also MN → YT prefix |
| v4 | `schema_v4_photo_lock.sql` | Photo lock, storage policies. **Create `cattle-photos` (private) bucket first** |
| v5 | `schema_v5_tag_lifecycle.sql` | Retire, recycle, reassign tags |
| v6 | `schema_v6_demo_setup.sql` | Demo animals (superseded by v12) |
| v7 | `schema_v7_public_page.sql` | Public lookup, scan alerts, lost/found |
| v8 | `schema_v8_dashboard.sql` | Milk edit limit, vaccine dates, dashboard view |
| v9 | `schema_v9_delete.sql` | Archive and delete functions |
| v10 | `schema_v10_rename.sql` | Farm names → Наран, Хангай, Тэрэлж |
| v11 | `schema_v11_public_minimal.sql` | Public page cut to photo + ID + call. **Create `cattle-public` (PUBLIC) bucket first** |
| v12 | `schema_v12_cleanup.sql` | Delete all seeded animals, keep the 5 real ones |
| v13 | `schema_v13_scan_fix.sql` | Public taps now appear on the dashboard map |
| v14 | `schema_v14_photo_fix.sql` | Photo pointer saved via function, not blocked UPDATE |
| v15 | `schema_v15_photo_backfill.sql` | Repair old photo pointers, report file sizes |

## Utilities (safe to run any time, change nothing)

- `system_check.sql` — full health report: RLS, views, counts, buckets
- `photo_diagnose.sql` — why a photo isn't showing

## Two buckets, deliberately different

- `cattle-photos` — **private.** Muzzle prints, evidence. Signed URLs only.
- `cattle-public` — **public.** One profile shot per animal, for the tap page.

## After any patch

Verify isolation still holds: log in as `admin12@yaktag.test` and
`admin07@yaktag.test` and confirm they see different animals.
