-- ============================================================
-- YAK-TAG — schema patch v3
-- Run in Supabase SQL Editor as role "postgres".
--
-- 1. CRITICAL FIX: views were bypassing Row Level Security.
-- 2. Tag prefix MN -> YT.
-- 3. Herders see only their own animals.
-- ============================================================

-- ============================================================
-- 1. CRITICAL — make views respect RLS
--
-- A Postgres view normally runs with the permissions of whoever
-- OWNS the view (postgres), not whoever QUERIES it. So every
-- user reading cattle_dashboard was reading it as postgres, who
-- bypasses RLS — which is why every login showed all 60 animals.
--
-- security_invoker = on makes the view run as the CALLING user,
-- so the RLS policies on the underlying tables apply properly.
-- Requires Postgres 15+ (Supabase projects are 15+).
-- ============================================================
alter view cattle_dashboard set (security_invoker = on);
alter view cattle_overview  set (security_invoker = on);
alter view farm_stats       set (security_invoker = on);

-- ============================================================
-- 2. TAG PREFIX: MN -> YT
-- ============================================================

-- new batches default to YT
alter table tag_batches alter column prefix set default 'YT';

-- update existing batches
update tag_batches set prefix = 'YT' where prefix = 'MN';

-- rewrite existing tag codes: MN-008000 -> YT-008000
update tags   set tag_code = replace(tag_code, 'MN-', 'YT-') where tag_code like 'MN-%';
update cattle set tag_code = replace(tag_code, 'MN-', 'YT-') where tag_code like 'MN-%';

-- ============================================================
-- 3. HERDERS SEE ONLY THEIR OWN ANIMALS
--
-- Previously: any herder could see every animal on their farm.
-- Now: farm_admin and super_admin see the whole farm; a herder
-- sees only animals they own.
-- ============================================================
drop policy if exists cattle_scope on cattle;
create policy cattle_scope on cattle for select
  using (
    is_super()
    or (my_role() = 'farm_admin' and farm_id = my_farm())
    or (my_role() = 'herder' and owner_id = auth.uid())
  );

-- milk: same shape — herder sees only their own animals' milk
drop policy if exists milk_scope on milk_yield;
create policy milk_scope on milk_yield for select
  using (
    is_super()
    or (my_role() = 'farm_admin' and farm_id = my_farm())
    or (my_role() = 'herder' and exists (
          select 1 from cattle c
          where c.id = milk_yield.cattle_id and c.owner_id = auth.uid()))
  );

-- scan events: same shape
drop policy if exists scans_scope on scan_events;
create policy scans_scope on scan_events for select
  using (
    is_super()
    or (my_role() = 'farm_admin' and farm_id = my_farm())
    or (my_role() = 'herder' and scanned_by = auth.uid())
  );

-- photos: same shape
drop policy if exists photos_scope on cattle_photos;
create policy photos_scope on cattle_photos for select
  using (
    is_super()
    or (my_role() = 'farm_admin' and farm_id = my_farm())
    or (my_role() = 'herder' and exists (
          select 1 from cattle c
          where c.id = cattle_photos.cattle_id and c.owner_id = auth.uid()))
  );

-- health events: same shape
drop policy if exists health_scope on health_events;
create policy health_scope on health_events for select
  using (
    is_super()
    or (my_role() = 'farm_admin' and farm_id = my_farm())
    or (my_role() = 'herder' and exists (
          select 1 from cattle c
          where c.id = health_events.cattle_id and c.owner_id = auth.uid()))
  );

-- ============================================================
-- VERIFY — after running this, log into the dashboard as each user.
-- Expected counts:
--   super@yaktag.test    -> 60   (everything)
--   admin12@yaktag.test  -> 50   (Farm 12 only)
--   admin07@yaktag.test  -> 10   (Farm 7 only)
--   bat@yaktag.test      -> 25   (only Bat-Erdene's own animals)
--   ganzo@yaktag.test    -> 25   (only Ganzorig's own animals)
--
-- If everyone still sees 60, the security_invoker change did not
-- take — check that step 1 ran without error.
-- ============================================================
