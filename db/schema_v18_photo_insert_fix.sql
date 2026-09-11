-- ============================================================
-- YAK-TAG — schema patch v18
--
-- BUG: "new row violates row-level security policy for table
--       cattle_photos"
--
-- The storage upload now succeeds (v16 fixed that), but writing
-- the accompanying row into cattle_photos is rejected.
--
-- Cause: the insert policy from the original schema checks
-- farm_id = my_farm(). Successive patches replaced the update and
-- delete policies on this table but never restated the insert one,
-- and somewhere along the way it stopped matching — most likely
-- because the row also carries locked_at / locked_by, which the
-- original policy's check did not anticipate.
--
-- Fix: restate every cattle_photos policy explicitly, so the whole
-- set is visible in one place instead of scattered across patches.
-- ============================================================

-- ---------- SEE WHAT IS THERE NOW ----------
select 'BEFORE — policies on cattle_photos' as step;
select policyname, cmd, qual, with_check
from pg_policies
where schemaname = 'public' and tablename = 'cattle_photos'
order by policyname;

-- ---------- CLEAR AND REBUILD ----------
drop policy if exists photos_scope    on cattle_photos;
drop policy if exists photos_insert   on cattle_photos;
drop policy if exists photos_update   on cattle_photos;
drop policy if exists photos_delete   on cattle_photos;
drop policy if exists cattle_photos_select on cattle_photos;
drop policy if exists cattle_photos_insert on cattle_photos;

-- READ: super sees all, farm admin sees their farm,
--       herder sees only their own animals
create policy photos_scope on cattle_photos for select
  using (
    is_super()
    or (my_role() = 'farm_admin' and farm_id = my_farm())
    or (my_role() = 'herder' and exists (
          select 1 from cattle c
          where c.id = cattle_photos.cattle_id and c.owner_id = auth.uid()))
  );

-- WRITE: anyone signed in may add a photo to an animal they can reach.
-- Checked against the ANIMAL rather than the submitted farm_id, so a
-- mismatched or missing farm_id in the payload cannot block a
-- legitimate save.
create policy photos_insert on cattle_photos for insert
  with check (
    exists (
      select 1 from cattle c
      where c.id = cattle_photos.cattle_id
        and (
          is_super()
          or (my_role() = 'farm_admin' and c.farm_id = my_farm())
          or (my_role() = 'herder' and c.owner_id = auth.uid())
        )
    )
  );

-- CHANGE / REMOVE: super admin only, per the photo-lock design
create policy photos_update on cattle_photos for update
  using (is_super());

create policy photos_delete on cattle_photos for delete
  using (is_super());

-- ---------- RESULT ----------
select 'AFTER — policies on cattle_photos' as step;
select policyname, cmd
from pg_policies
where schemaname = 'public' and tablename = 'cattle_photos'
order by policyname;

-- ---------- SANITY ----------
-- Confirm the helper functions return what the policies expect.
-- Run this while impersonating bat@yaktag.test if you can:
--   select my_role(), my_farm(), is_super();

-- ============================================================
-- LOCK ON INSERT, SERVER-SIDE
--
-- The client used to send locked_at itself. That is the wrong place
-- for it: a browser should not declare that its own record is
-- immutable. A trigger sets it, so every photo is locked the moment
-- it exists, with no way for a client to opt out.
-- ============================================================
create or replace function lock_photo_on_insert()
returns trigger language plpgsql as $$
begin
  new.locked_at := now();
  new.locked_by := auth.uid();
  return new;
end $$;

drop trigger if exists photo_autolock on cattle_photos;
create trigger photo_autolock
  before insert on cattle_photos
  for each row execute function lock_photo_on_insert();
