-- ============================================================
-- YAK-TAG — schema patch v4
-- Run in Supabase SQL Editor as role "postgres".
--
-- 1. Photo lock: once a photo is locked it can never be edited.
-- 2. Storage bucket policies for the cattle-photos bucket.
-- 3. Feeding helper.
-- ============================================================

-- ============================================================
-- 1. PHOTO LOCK
--
-- Locking is per-PHOTO, not per-cow, on purpose: the registration
-- photo evidence becomes immutable, but the cow record itself
-- stays editable (weight, health, ownership all keep working).
-- ============================================================
alter table cattle_photos
  add column if not exists locked_at   timestamptz,
  add column if not exists locked_by   uuid references profiles(id),
  add column if not exists sha256      text;   -- integrity check of the file

-- Once locked_at is set, the row is frozen. The only way past this
-- is a farm_admin override, which is logged (see unlock_photo below).
create or replace function prevent_locked_photo_edit()
returns trigger language plpgsql as $$
begin
  if old.locked_at is not null then
    raise exception 'This photo is locked and cannot be changed (locked at %)', old.locked_at
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

drop trigger if exists photo_lock_guard on cattle_photos;
create trigger photo_lock_guard
  before update or delete on cattle_photos
  for each row execute function prevent_locked_photo_edit();

-- Farm admins can undo a lock (wrong cow tapped, bad photo), but the
-- override is written to audit_log so it is never silent.
create or replace function unlock_photo(photo_id uuid, reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  p record;
begin
  select * into p from cattle_photos where id = photo_id;
  if not found then
    raise exception 'Photo not found';
  end if;

  if not (is_super() or (my_role() = 'farm_admin' and p.farm_id = my_farm())) then
    raise exception 'Only a farm admin can unlock a photo';
  end if;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (p.farm_id, auth.uid(), 'photo_unlock', 'cattle_photos', photo_id,
          jsonb_build_object('reason', reason,
                             'was_locked_at', p.locked_at,
                             'was_locked_by', p.locked_by));

  -- bypass the guard by clearing the lock directly
  update cattle_photos set locked_at = null, locked_by = null
  where id = photo_id;
end $$;

-- allow the update policy to set the lock
drop policy if exists photos_update on cattle_photos;
create policy photos_update on cattle_photos for update
  using (
    is_super()
    or (my_role() = 'farm_admin' and farm_id = my_farm())
    or (my_role() = 'herder' and exists (
          select 1 from cattle c
          where c.id = cattle_photos.cattle_id and c.owner_id = auth.uid()))
  );

-- ============================================================
-- 2. STORAGE BUCKET POLICIES
--
-- Create the bucket first in the dashboard:
--   Storage -> New bucket -> name: cattle-photos -> PRIVATE (not public)
-- Then run these policies.
--
-- Path convention: farm-<farm_id>/cow-<cattle_id>/<kind>-<ts>.jpg
-- The first path segment carries the farm id, so we can check
-- farm ownership straight from the object name.
-- ============================================================

-- read: same scoping as the photo rows themselves
create policy "cattle photos read"
on storage.objects for select
to authenticated
using (
  bucket_id = 'cattle-photos'
  and (
    is_super()
    or (storage.foldername(name))[1] = 'farm-' || my_farm()::text
  )
);

-- write: any signed-in user may upload into their own farm's folder
create policy "cattle photos insert"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'cattle-photos'
  and (storage.foldername(name))[1] = 'farm-' || my_farm()::text
);

-- no update / no delete policies on purpose.
-- Photo files are write-once, matching the lock rule above.

-- ============================================================
-- 3. FEEDING — convenience function so the UI is one call
-- ============================================================
create or replace function log_feeding(
  p_cattle_id uuid,
  p_title text default 'Тэжээл',
  p_detail text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_farm uuid;
  v_id uuid;
begin
  select farm_id into v_farm from cattle where id = p_cattle_id;
  if v_farm is null then
    raise exception 'Cattle not found';
  end if;

  insert into health_events (farm_id, cattle_id, kind, title, detail, recorded_by)
  values (v_farm, p_cattle_id, 'feeding', p_title, p_detail, auth.uid())
  returning id into v_id;

  return v_id;
end $$;

-- ============================================================
-- END v4
-- ============================================================
