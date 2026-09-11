# Database patches — run in this order

Each file is applied once, in Supabase SQL Editor, with the role set to
`postgres` (not an impersonated user).

| File | What it does |
|---|---|
| `schema.sql` | Base tables, RLS policies, triggers (from the original repo) |
| `seed.sql` | 3 farms, 5 users, 60 cattle, 25 tags — test data |
| `schema_v3_rls_fix.sql` | **Critical.** Views were bypassing RLS; adds `security_invoker`. Also renames tag prefix MN → YT and scopes herders to their own animals |
| `schema_v4_photo_lock.sql` | Photo lock trigger, storage bucket policies, feeding events. **Create the `cattle-photos` bucket (private) in Storage first** |
| `schema_v5_tag_lifecycle.sql` | Retire, recycle and reassign physical tags |
| `schema_v6_demo_setup.sql` | Assigns YT-008000..004 to one farmer, generates 14 days of milk |
| `schema_v7_public_page.sql` | Public tap lookup, scan alerts, lost/found reporting |
| `schema_v8_dashboard.sql` | Milk edit limit (3), vaccination dates, dashboard view, admin edit |
| `schema_v9_delete.sql` | Archive and delete functions for farms, users, cattle, tags |
| `schema_v10_rename.sql` | Simpler farm names |

## Notes

- Patches are additive and use `if not exists` where possible, so
  re-running one is usually safe — but check before you do.
- v8 contains a safety block that creates anything v7 should have added,
  so it survives a partial v7.
- After v3, always verify isolation: log in as `admin12@yaktag.test` and
  confirm the dashboard shows 50 animals, not 60.
