-- ============================================================
-- YAK-TAG — schema patch v19
--
-- BUG 1: "This photo is locked and cannot be changed"
--        when the SUPER ADMIN tries to delete it.
--
--   delete_photo() clears the lock before deleting, but the lock
--   trigger fires on that very update and rejects it. The lock was
--   protecting itself from the one function meant to override it.
--
-- BUG 2: the trigger returns NEW on DELETE. NEW is null in a BEFORE
--        DELETE trigger, and returning null silently cancels the
--        delete. So even past bug 1, nothing would have been removed.
--
-- Fix: an explicit override flag, set only inside the admin
-- functions and scoped to the transaction. Everyone else still hits
-- the lock exactly as before.
-- ============================================================

create or replace function prevent_locked_photo_edit()
returns trigger language plpgsql as $$
begin
  -- Admin functions set this flag for the duration of their own
  -- transaction. Nothing else can set it, and it cannot leak between
  -- statements, so the lock stays real for ordinary writes.
  if coalesce(current_setting('yaktag.photo_admin', true), '') = 'on' then
    return coalesce(new, old);
  end if;

  if old.locked_at is not null then
    raise exception 'This photo is locked and cannot be changed (locked at %)', old.locked_at
      using errcode = 'check_violation';
  end if;

  -- BEFORE DELETE must return OLD; returning NEW (null) cancels it
  return coalesce(new, old);
end $$;

drop trigger if exists photo_lock_guard on cattle_photos;
create trigger photo_lock_guard
  before update or delete on cattle_photos
  for each row execute function prevent_locked_photo_edit();

-- ============================================================
-- DELETE — super admin only, logged, override flag set
-- ============================================================
create or replace function delete_photo(photo_id uuid, reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  p record;
begin
  select * into p from cattle_photos where id = photo_id;
  if not found then raise exception 'Photo not found'; end if;

  if not is_super() then
    raise exception 'Only the super admin can delete a photo';
  end if;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (p.farm_id, auth.uid(), 'photo_delete', 'cattle_photos', photo_id,
          jsonb_build_object('reason', reason,
                             'storage_path', p.storage_path,
                             'kind', p.kind,
                             'taken_at', p.taken_at));

  -- clearing the pointer lets the next profile photo auto-publish
  -- instead of leaving the tap page pointing at a deleted file
  if p.kind = 'profile' then
    update cattle set public_photo_path = null where id = p.cattle_id;
  end if;

  perform set_config('yaktag.photo_admin', 'on', true);   -- true = this transaction only
  delete from cattle_photos where id = photo_id;
  perform set_config('yaktag.photo_admin', 'off', true);
end $$;

-- ============================================================
-- UNLOCK — same override, same logging
-- ============================================================
create or replace function unlock_photo(photo_id uuid, reason text)
returns void language plpgsql security definer set search_path = public as $$
declare p record;
begin
  select * into p from cattle_photos where id = photo_id;
  if not found then raise exception 'Photo not found'; end if;

  if not is_super() then
    raise exception 'Only the super admin can unlock a photo';
  end if;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (p.farm_id, auth.uid(), 'photo_unlock', 'cattle_photos', photo_id,
          jsonb_build_object('reason', reason, 'was_locked_at', p.locked_at));

  perform set_config('yaktag.photo_admin', 'on', true);
  update cattle_photos set locked_at = null, locked_by = null where id = photo_id;
  perform set_config('yaktag.photo_admin', 'off', true);
end $$;

-- ============================================================
-- The cleanup and cascade functions need the same override, or a
-- locked photo blocks deleting the animal that owns it.
-- ============================================================
create or replace function delete_cattle(p_cattle_id uuid, p_force boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  c record;
  n_milk int; n_photo int; n_scan int;
begin
  if not is_super() then raise exception 'Super admin only'; end if;

  select * into c from cattle where id = p_cattle_id;
  if not found then raise exception 'Animal not found'; end if;

  select count(*) into n_milk  from milk_yield    where cattle_id = p_cattle_id;
  select count(*) into n_photo from cattle_photos where cattle_id = p_cattle_id;
  select count(*) into n_scan  from public_scans  where cattle_id = p_cattle_id;

  if not p_force and (n_milk > 0 or n_photo > 0 or n_scan > 0) then
    raise exception
      'Animal has records (% milk, % photos, % public scans). Archive it, or pass force.',
      n_milk, n_photo, n_scan;
  end if;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (c.farm_id, auth.uid(), 'cattle_delete', 'cattle', p_cattle_id,
          jsonb_build_object('tag_code', c.tag_code, 'forced', p_force,
                             'milk', n_milk, 'photos', n_photo, 'scans', n_scan));

  update tags set status = 'recycled', nfc_uid = null where id = c.tag_id;

  perform set_config('yaktag.photo_admin', 'on', true);
  delete from cattle where id = p_cattle_id;
  perform set_config('yaktag.photo_admin', 'off', true);
end $$;

-- ============================================================
-- CHECK
--   Log in as super@yaktag.test, open a cow page, press Устгах.
--   The photo should disappear and a row should appear in audit_log:
--     select action, detail, created_at from audit_log
--      where action = 'photo_delete' order by created_at desc limit 5;
-- ============================================================
