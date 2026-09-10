-- ============================================================
-- YAK-TAG — schema patch v9
-- Deleting things, safely.
--
-- Design rule: archive by default, hard-delete only on explicit
-- request. A traceability system whose records vanish is not a
-- traceability system — but during a pilot you also need to
-- clear out test data, so both paths exist and both are logged.
-- ============================================================

-- ============================================================
-- 1. ARCHIVE (the safe default)
-- ============================================================
alter table farms
  add column if not exists archived_at timestamptz;

alter table cattle
  add column if not exists archived_at timestamptz;

-- ---- archive a farm: hides it, keeps every record ----
create or replace function archive_farm(p_farm_id uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_super() then raise exception 'Super admin only'; end if;

  update farms set status = 'suspended', archived_at = now() where id = p_farm_id;
  update profiles set active = false where farm_id = p_farm_id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (p_farm_id, auth.uid(), 'farm_archive', 'farms', p_farm_id,
          jsonb_build_object('reason', p_reason));
end $$;

create or replace function restore_farm(p_farm_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_super() then raise exception 'Super admin only'; end if;
  update farms set status = 'active', archived_at = null where id = p_farm_id;
  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (p_farm_id, auth.uid(), 'farm_restore', 'farms', p_farm_id, '{}'::jsonb);
end $$;

-- ============================================================
-- 2. HARD DELETE — for clearing pilot/test data
--
-- Refuses when real activity exists, unless p_force is true.
-- "Real activity" = milk entries, photos, or public scans. Those
-- are the records someone might later need to prove something.
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
      'Animal has records (% milk, % photos, % public scans). Archive it, or pass force to delete anyway.',
      n_milk, n_photo, n_scan;
  end if;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (c.farm_id, auth.uid(), 'cattle_delete', 'cattle', p_cattle_id,
          jsonb_build_object('tag_code', c.tag_code, 'forced', p_force,
                             'milk', n_milk, 'photos', n_photo, 'scans', n_scan));

  -- free the tag so it can be reissued
  update tags set status = 'recycled', nfc_uid = null where id = c.tag_id;

  -- photo lock guard would block the cascade
  update cattle_photos set locked_at = null, locked_by = null where cattle_id = p_cattle_id;

  delete from cattle where id = p_cattle_id;
end $$;

-- ---- delete a tag ----
create or replace function delete_tag(p_tag_code text, p_force boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  t record; c record;
begin
  if not is_super() then raise exception 'Super admin only'; end if;

  select * into t from tags where tag_code = p_tag_code;
  if not found then raise exception 'Tag % not found', p_tag_code; end if;

  select * into c from cattle where tag_id = t.id;
  if found and not p_force then
    raise exception 'Tag % is on animal %. Detach it first, or pass force.',
      p_tag_code, c.tag_code;
  end if;

  if found then update cattle set tag_id = null where tag_id = t.id; end if;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (t.farm_id, auth.uid(), 'tag_delete', 'tags', t.id,
          jsonb_build_object('tag_code', p_tag_code, 'forced', p_force));

  delete from tags where id = t.id;
end $$;

-- ---- delete a user profile ----
-- Note: this removes the PROFILE, not the auth account. Removing the
-- auth login is done in Supabase Authentication, deliberately kept
-- separate so a mis-click here cannot lock someone out permanently.
create or replace function delete_profile(p_profile_id uuid, p_force boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  p record; n_cattle int;
begin
  if not is_super() then raise exception 'Super admin only'; end if;
  if p_profile_id = auth.uid() then raise exception 'You cannot delete yourself'; end if;

  select * into p from profiles where id = p_profile_id;
  if not found then raise exception 'User not found'; end if;

  select count(*) into n_cattle from cattle where owner_id = p_profile_id;
  if n_cattle > 0 and not p_force then
    raise exception 'User owns % animals. Reassign them first, or pass force.', n_cattle;
  end if;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (p.farm_id, auth.uid(), 'profile_delete', 'profiles', p_profile_id,
          jsonb_build_object('name', p.full_name, 'role', p.role,
                             'cattle_owned', n_cattle, 'forced', p_force));

  delete from profiles where id = p_profile_id;
end $$;

-- ---- delete a farm ----
create or replace function delete_farm(p_farm_id uuid, p_force boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  f record; n_cattle int; n_users int;
begin
  if not is_super() then raise exception 'Super admin only'; end if;

  select * into f from farms where id = p_farm_id;
  if not found then raise exception 'Farm not found'; end if;

  select count(*) into n_cattle from cattle where farm_id = p_farm_id;
  select count(*) into n_users  from profiles where farm_id = p_farm_id;

  if not p_force and (n_cattle > 0 or n_users > 0) then
    raise exception 'Farm has % animals and % users. Archive it, or pass force.',
      n_cattle, n_users;
  end if;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (null, auth.uid(), 'farm_delete', 'farms', p_farm_id,
          jsonb_build_object('code', f.code, 'name', f.name,
                             'cattle', n_cattle, 'users', n_users, 'forced', p_force));

  if p_force then
    update cattle_photos set locked_at = null, locked_by = null
      where farm_id = p_farm_id;
    delete from cattle   where farm_id = p_farm_id;
    delete from tags     where farm_id = p_farm_id;
    delete from profiles where farm_id = p_farm_id;
  end if;

  delete from farms where id = p_farm_id;
end $$;

-- ---- create a farm ----
create or replace function create_farm(
  p_code text, p_name text, p_aimag text, p_soum text,
  p_lat numeric default null, p_lng numeric default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not is_super() then raise exception 'Super admin only'; end if;

  insert into farms (code, name, aimag, soum, center_lat, center_lng, status)
  values (p_code, p_name, p_aimag, p_soum, p_lat, p_lng, 'active')
  returning id into v_id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (v_id, auth.uid(), 'farm_create', 'farms', v_id,
          jsonb_build_object('code', p_code, 'name', p_name));
  return v_id;
end $$;

-- ============================================================
-- 3. FARM LIST for the admin screen
-- ============================================================
create or replace view admin_farms as
select f.id, f.code, f.name, f.aimag, f.soum, f.status,
       f.center_lat, f.center_lng, f.archived_at,
       (select count(*) from cattle c   where c.farm_id = f.id) as cattle_count,
       (select count(*) from profiles p where p.farm_id = f.id) as user_count,
       (select count(*) from tags t     where t.farm_id = f.id) as tag_count
from farms f
order by f.code;

alter view admin_farms set (security_invoker = on);

drop policy if exists farms_admin_all on farms;
create policy farms_admin_all on farms for all
  using (is_super()) with check (is_super());

drop policy if exists tags_admin_all on tags;
create policy tags_admin_all on tags for all
  using (is_super()) with check (is_super());

-- ============================================================
-- 4. TRIM THE DEMO DATA
--    Keep the 5 tagged animals and Farm 12. Archive the rest so
--    the pilot looks like a pilot, not a dump of seed rows.
--    (Archived, not deleted — reversible with restore_farm.)
-- ============================================================
do $$
declare f7 uuid; f3 uuid;
begin
  select id into f7 from farms where code = 'FERM-07';
  select id into f3 from farms where code = 'FERM-03';
  -- left active on purpose so you can still demo multi-farm isolation.
  -- To hide them:  select archive_farm(id, 'demo cleanup') from farms where code in ('FERM-07','FERM-03');
  raise notice 'Farms 7 and 3 left active for the isolation demo.';
end $$;

-- ============================================================
-- END v9
-- ============================================================
