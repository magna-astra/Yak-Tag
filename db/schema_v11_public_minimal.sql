-- ============================================================
-- YAK-TAG — schema patch v11
-- The public page shows three things: photo, tag number, call.
-- Everything else requires a login.
-- ============================================================

-- ============================================================
-- 1. CONTACT PHONE, SET BY THE HERDER, LOCKABLE
--
-- Kept on the animal rather than the profile so a sold or
-- transferred animal can carry a different contact without
-- touching the owner's account.
-- ============================================================
alter table cattle
  add column if not exists contact_phone      text,
  add column if not exists contact_locked_at  timestamptz,
  add column if not exists contact_locked_by  uuid references profiles(id);

-- seed from the owner's number so existing animals have something
update cattle c
   set contact_phone = p.phone
  from profiles p
 where p.id = c.owner_id
   and c.contact_phone is null;

-- Once locked, the number is frozen. Only a farm admin can reopen it,
-- and the override is written to audit_log.
create or replace function set_contact_phone(
  p_cattle_id uuid,
  p_phone     text,
  p_lock      boolean default false
) returns void language plpgsql security definer set search_path = public as $$
declare c record;
begin
  select * into c from cattle where id = p_cattle_id;
  if not found then raise exception 'Animal not found'; end if;

  if not (is_super()
          or (my_role() = 'farm_admin' and c.farm_id = my_farm())
          or (my_role() = 'herder' and c.owner_id = auth.uid())) then
    raise exception 'Not allowed';
  end if;

  if c.contact_locked_at is not null and not (is_super() or my_role() = 'farm_admin') then
    raise exception 'This number is locked. Ask a farm admin to change it.';
  end if;

  update cattle
     set contact_phone = p_phone,
         contact_locked_at = case when p_lock then now() else contact_locked_at end,
         contact_locked_by = case when p_lock then auth.uid() else contact_locked_by end
   where id = p_cattle_id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (c.farm_id, auth.uid(), 'set_contact_phone', 'cattle', p_cattle_id,
          jsonb_build_object('locked', p_lock));
end $$;

create or replace function unlock_contact_phone(p_cattle_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare c record;
begin
  select * into c from cattle where id = p_cattle_id;
  if not found then raise exception 'Animal not found'; end if;

  if not (is_super() or (my_role() = 'farm_admin' and c.farm_id = my_farm())) then
    raise exception 'Only a farm admin can unlock a number';
  end if;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (c.farm_id, auth.uid(), 'unlock_contact_phone', 'cattle', p_cattle_id,
          jsonb_build_object('reason', p_reason));

  update cattle set contact_locked_at = null, contact_locked_by = null
   where id = p_cattle_id;
end $$;

-- ============================================================
-- 2. PUBLIC PHOTO BUCKET
--
-- The main cattle-photos bucket is private and must stay that way:
-- it holds muzzle prints and evidence. One profile shot per animal
-- is copied into a public bucket so the tap page can display it
-- without exposing anything else.
--
-- Create the bucket first, in Storage:
--   New bucket -> name: cattle-public -> PUBLIC
-- Then run the policy below.
-- ============================================================
alter table cattle
  add column if not exists public_photo_path text;

do $$
begin
  execute $p$
    create policy "public photo insert"
    on storage.objects for insert
    to authenticated
    with check (bucket_id = 'cattle-public'
                and (storage.foldername(name))[1] = 'farm-' || my_farm()::text)
  $p$;
exception when duplicate_object then null;
end $$;

-- ============================================================
-- 3. THE PUBLIC LOOKUP — now only what a finder needs
--
-- Deliberately absent: owner name, farm name, soum, breed, age,
-- sex, weight, milk, health, GPS. A stolen animal is held by the
-- thief, and the same page serves them. Every extra field is a
-- profile of the victim handed to whoever took the animal.
-- ============================================================
drop function if exists public_tag_lookup(text);

create or replace function public_tag_lookup(p_tag_code text)
returns table (
  tag_code    text,
  photo_path  text,
  has_phone   boolean,
  phone       text,
  is_lost     boolean
) language sql security definer set search_path = public as $$
  select
    c.tag_code,
    c.public_photo_path,
    (c.contact_phone is not null),
    c.contact_phone,
    (c.reported_lost_at is not null or c.status in ('lost','stolen'))
  from cattle c
  join farms f on f.id = c.farm_id
  where c.tag_code = p_tag_code
    and f.status = 'active';
$$;

grant execute on function public_tag_lookup(text) to anon, authenticated;

-- ============================================================
-- CHECK
--   select * from public_tag_lookup('YT-008000');
-- Five columns only. If you see farm or owner names, the old
-- version is still in place.
-- ============================================================

-- ============================================================
-- 4. EXPOSE CONTACT FIELDS TO THE LOGGED-IN VIEW
-- ============================================================
-- Postgres refuses to reorder or rename view columns with CREATE OR
-- REPLACE, so the view is dropped and rebuilt. Nothing depends on it
-- except the app, which re-queries on load.
drop view if exists cattle_dashboard;

create view cattle_dashboard as
select
  c.id, c.farm_id, c.tag_code, c.sex, c.birth_year, c.breed,
  c.weight_kg, c.status, c.owner_id,
  c.reported_lost_at,
  c.contact_phone, c.contact_locked_at, c.public_photo_path,
  p.full_name  as owner_name,
  f.name       as farm_name,
  f.code       as farm_code,
  f.center_lat as farm_lat,
  f.center_lng as farm_lng,
  s.scanned_at as last_seen_at,
  s.lat        as last_lat,
  s.lng        as last_lng,
  today_milk.liters      as milk_today,
  today_milk.edit_count  as milk_edits,
  today_milk.locked      as milk_locked,
  today_milk.id          as milk_id,
  month_milk.total       as milk_this_month,
  last_feed.occurred_at  as last_fed_at,
  vac.given_on           as last_vaccination,
  vac.due_next           as next_vaccination_due,
  vac.vaccine_name       as vaccine_name,
  (select count(*) from public_scans ps
     where ps.cattle_id = c.id and ps.scanned_at > now() - interval '30 days')
                         as public_scans_30d
from cattle c
join profiles p on p.id = c.owner_id
join farms f    on f.id = c.farm_id
left join lateral (
  select * from scan_events e where e.cattle_id = c.id
  order by e.scanned_at desc limit 1) s on true
left join lateral (
  select id, liters, edit_count, locked from milk_yield m
  where m.cattle_id = c.id and m.yield_date = current_date) today_milk on true
left join lateral (
  select sum(liters) as total from milk_yield m
  where m.cattle_id = c.id
    and date_trunc('month', m.yield_date) = date_trunc('month', current_date)
) month_milk on true
left join lateral (
  select occurred_at from health_events h
  where h.cattle_id = c.id and h.kind = 'feeding'
  order by occurred_at desc limit 1) last_feed on true
left join lateral (
  select given_on, due_next, vaccine_name from health_events h
  where h.cattle_id = c.id and h.kind = 'vaccination'
  order by coalesce(given_on, occurred_at::date) desc limit 1) vac on true;

alter view cattle_dashboard set (security_invoker = on);
