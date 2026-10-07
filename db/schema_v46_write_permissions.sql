-- ============================================================
-- YAK-TAG — schema patch v46
-- Close direct-write loopholes found in the 2026-10-07 security check.
--
-- The app changes animals, tags, people and health records ONLY through
-- database functions (security definer, which check who is asking).
-- But some tables still had their original "write directly" rules from
-- schema.sql / v7, which anyone signed in (or, for public_scans, anyone
-- at all) could use with a hand-made web request:
--
--  1. profiles_admin let a FARM ADMIN change their own row — including
--     role = 'super_admin'. That would give them every farm, phone and
--     order, and the admin-users function would then let them reset the
--     real super admin's password.
--  2. public_scan_insert let ANYONE write a "lost animal" scan straight
--     into public_scans with was_lost = true, which sent fake Telegram
--     alerts with a fake map pin for any animal with a public photo.
--  3. cattle / tags / health_events: a herder could PATCH their own
--     animal's contact_phone past the lock, copy another animal's
--     tag_code, or move it to another farm — with no audit history.
--  4. milk_yield: a herder could reset edit_count to 0 and so dodge
--     the 3-edit lock.
--
-- The fix removes direct INSERT / UPDATE / DELETE on those tables for
-- browsers (anon, authenticated). The functions keep working because
-- they run as the table owner. What the app still writes directly is
-- untouched: milk_yield (upsert), cattle_photos (insert), scan_events
-- (insert) — and the milk counter is now kept by the server only.
--
-- Also: the lost-animal alert re-checks the animal in the database, and
-- the two photo buckets get a 10 MB / image-only limit (the app uploads
-- ~0.3 MB JPEGs).
--
-- No rows are changed or deleted. Safe on the live project and safe to
-- run twice. Nothing in the website or app needs to change for it.
-- ============================================================

do $$
begin
  if to_regprocedure('public.scan_caller_hash()') is null or to_regclass('public.public_scans') is null then
    raise exception 'Wrong database: this is not the YAK-TAG project (oxfbxqclqfglpzgzizhq). Open the right project and run again.';
  end if;
end $$;

-- ---------- 1. profiles: only the functions and the admin-users Edge Function write ----------
-- Its SELECT part is already covered by profiles_self.
drop policy if exists profiles_admin on public.profiles;
revoke insert, update, delete, truncate on public.profiles from anon, authenticated;

-- ---------- 2. public_scans: only record_public_scan() writes ----------
drop policy if exists public_scan_insert on public.public_scans;
revoke insert, update, delete, truncate on public.public_scans from anon, authenticated;

-- ---------- 3. animals, tags, health records: only the functions write ----------
revoke insert, update, delete, truncate on public.cattle        from anon, authenticated;
revoke insert, update, delete, truncate on public.tags          from anon, authenticated;
revoke insert, update, delete, truncate on public.health_events from anon, authenticated;

-- ---------- 4. milk: the edit counter and lock belong to the server ----------
-- Same rule as v8 (3 corrections, then locked), but values a browser
-- sends for edit_count / locked / last_edited_at are ignored.
create or replace function public.count_milk_edit()
returns trigger language plpgsql as $$
begin
  new.edit_count     := old.edit_count;
  new.locked         := old.locked;
  new.last_edited_at := old.last_edited_at;
  -- only count real value changes, not no-op updates
  if new.liters is distinct from old.liters then
    new.edit_count := old.edit_count + 1;
    new.last_edited_at := now();
    if new.edit_count >= 3 then
      new.locked := true;
    end if;
  end if;
  return new;
end $$;

-- ---------- 5. lost-animal alert: trust the animal, not the scan row ----------
-- Same test record_public_scan() and the app-scan alert already use.
create or replace function public.tg_on_public_scan() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.was_lost and exists (
       select 1 from cattle c
        where c.id = new.cattle_id
          and (c.reported_lost_at is not null or c.status in ('lost', 'stolen'))) then
    perform tg_alert_lost_scan(new.cattle_id, new.lat, new.lng, new.accuracy_m, new.scanned_at, null);
  end if;
  return null;
exception when others then
  return null;                        -- the scan is saved no matter what
end $$;
revoke all on function public.tg_on_public_scan() from public, anon, authenticated;

-- ---------- 6. photo buckets: images only, 10 MB each ----------
update storage.buckets
   set file_size_limit = 10485760,
       allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']
 where id in ('cattle-photos', 'cattle-public');

notify pgrst, 'reload schema';

-- ============================================================
-- CHECK (the results appear below after Run)
-- ============================================================
-- a) Super admins. Real ones have no farm. Anyone here you don't
--    recognise, or with a farm, was made super admin through the old
--    loophole — set them back in the dashboard.
select full_name, role, farm_id from public.profiles where role = 'super_admin';

-- b) Write rules a browser can still use directly. Expected tables:
--    cattle_photos (add; change/delete = super admin only), farms and
--    tag_batches (super admin only), milk_yield, scan_events.
--    profiles, public_scans, cattle, tags, health_events must NOT appear.
select p.tablename, p.policyname, p.cmd
  from pg_policies p
 where p.schemaname = 'public'
   and p.cmd <> 'SELECT'
   and exists (select 1 from information_schema.role_table_grants g
                where g.table_schema = 'public' and g.table_name = p.tablename
                  and g.grantee in ('anon', 'authenticated')
                  and g.privilege_type in ('INSERT', 'UPDATE', 'DELETE'))
 order by 1, 2;
