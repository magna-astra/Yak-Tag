-- ============================================================
-- YAK-TAG — schema patch v8
-- Milk edit limits, vaccination dates, map data, admin tools.
-- ============================================================

-- ============================================================
-- 0. SAFETY: columns this patch depends on.
--    Added here too so v8 runs cleanly even if an earlier patch
--    was only partly applied. All are no-ops if already present.
-- ============================================================
alter table profiles
  add column if not exists public_phone text,
  add column if not exists show_phone boolean not null default true,
  add column if not exists active boolean not null default true;

alter table cattle
  add column if not exists reported_lost_at timestamptz,
  add column if not exists lost_note text;

alter table health_events
  add column if not exists given_on date,
  add column if not exists vaccine_name text;

create table if not exists public_scans (
  id           uuid primary key default gen_random_uuid(),
  cattle_id    uuid not null references cattle(id) on delete cascade,
  farm_id      uuid not null references farms(id),
  scanned_at   timestamptz not null default now(),
  lat          numeric(9,6),
  lng          numeric(9,6),
  accuracy_m   numeric(7,1),
  user_agent   text,
  was_lost     boolean not null default false,
  contacted    boolean not null default false
);

-- ============================================================
-- 1. MILK EDIT LIMIT
--
-- A herder may correct a day's entry up to 3 times. After that
-- the number is frozen and only a farm admin can change it.
-- Rationale: honest mistakes happen (wrong cow, typo), but an
-- unlimited edit window makes the record worthless as evidence.
-- ============================================================
alter table milk_yield
  add column if not exists edit_count  integer not null default 0,
  add column if not exists last_edited_at timestamptz,
  add column if not exists locked      boolean not null default false;

create or replace function count_milk_edit()
returns trigger language plpgsql as $$
begin
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

drop trigger if exists milk_edit_counter on milk_yield;
create trigger milk_edit_counter
  before update on milk_yield
  for each row execute function count_milk_edit();

-- herders blocked once locked; farm admins may still correct
drop policy if exists milk_update on milk_yield;
create policy milk_update on milk_yield for update
  using (
    is_super()
    or (my_role() = 'farm_admin' and farm_id = my_farm())
    or (my_role() = 'herder'
        and recorded_by = auth.uid()
        and yield_date >= current_date - 1     -- yesterday and today
        and locked = false)
  );

-- ============================================================
-- 2. VACCINATION with proper dates
-- ============================================================
create or replace function log_vaccination(
  p_cattle_id  uuid,
  p_vaccine    text,
  p_given_on   date,
  p_next_due   date,
  p_note       text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_farm uuid;
  v_id uuid;
begin
  select farm_id into v_farm from cattle where id = p_cattle_id;
  if v_farm is null then raise exception 'Animal not found'; end if;

  insert into health_events
    (farm_id, cattle_id, kind, title, detail, vaccine_name,
     given_on, occurred_at, due_next, recorded_by)
  values
    (v_farm, p_cattle_id, 'vaccination', p_vaccine, p_note, p_vaccine,
     p_given_on, p_given_on::timestamptz, p_next_due, auth.uid())
  returning id into v_id;

  return v_id;
end $$;

-- ============================================================
-- 3. MAP + DASHBOARD VIEW (rebuilt)
-- ============================================================
drop view if exists cattle_dashboard;
create view cattle_dashboard as
select
  c.id, c.farm_id, c.tag_code, c.sex, c.birth_year, c.breed,
  c.weight_kg, c.status, c.owner_id,
  c.reported_lost_at,
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

-- milk for any chosen date, used by the date filter
create or replace function milk_on_date(p_date date)
returns table (cattle_id uuid, liters numeric, edit_count int, locked boolean)
language sql stable security invoker as $$
  select cattle_id, liters, edit_count, locked
  from milk_yield where yield_date = p_date;
$$;

-- ============================================================
-- 4. SUPER ADMIN — edit anything
-- ============================================================
create or replace function admin_update_cattle(
  p_cattle_id uuid,
  p_farm_id   uuid  default null,
  p_owner_id  uuid  default null,
  p_breed     text  default null,
  p_birth_year int  default null,
  p_weight    numeric default null,
  p_sex       text  default null,
  p_status    text  default null
) returns void language plpgsql security definer set search_path = public as $$
declare c record;
begin
  if not is_super() then raise exception 'Super admin only'; end if;
  select * into c from cattle where id = p_cattle_id;
  if not found then raise exception 'Animal not found'; end if;

  update cattle set
    farm_id    = coalesce(p_farm_id, farm_id),
    owner_id   = coalesce(p_owner_id, owner_id),
    breed      = coalesce(p_breed, breed),
    birth_year = coalesce(p_birth_year, birth_year),
    weight_kg  = coalesce(p_weight, weight_kg),
    sex        = coalesce(p_sex, sex),
    status     = coalesce(p_status, status)
  where id = p_cattle_id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (c.farm_id, auth.uid(), 'admin_edit_cattle', 'cattle', p_cattle_id,
          jsonb_build_object('from', to_jsonb(c)));
end $$;

create or replace function admin_update_profile(
  p_profile_id uuid,
  p_full_name  text default null,
  p_phone      text default null,
  p_role       text default null,
  p_farm_id    uuid default null,
  p_active     boolean default null
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_super() then raise exception 'Super admin only'; end if;

  update profiles set
    full_name = coalesce(p_full_name, full_name),
    phone     = coalesce(p_phone, phone),
    public_phone = coalesce(p_phone, public_phone),
    role      = coalesce(p_role, role),
    farm_id   = coalesce(p_farm_id, farm_id),
    active    = coalesce(p_active, active)
  where id = p_profile_id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (null, auth.uid(), 'admin_edit_profile', 'profiles', p_profile_id,
          jsonb_build_object('role', p_role, 'farm_id', p_farm_id));
end $$;

-- who the super admin can see / manage
create or replace view admin_users as
select p.id, p.full_name, p.phone, p.public_phone, p.role, p.active,
       p.farm_id, f.name as farm_name, f.code as farm_code,
       (select count(*) from cattle c where c.owner_id = p.id) as cattle_count
from profiles p
left join farms f on f.id = p.farm_id;

alter view admin_users set (security_invoker = on);

drop policy if exists profiles_admin_all on profiles;
create policy profiles_admin_all on profiles for all
  using (is_super()) with check (is_super());

-- ============================================================
-- 5. DEMO SCAN HISTORY so the maps have something to show
--
-- Generates plausible scan positions around Farm 12's centre for
-- the five demo animals. Clearly synthetic — delete before real
-- field data matters:  delete from scan_events where was_offline is null;
-- ============================================================
do $$
declare
  u_bat uuid := 'd422690e-534a-49b7-b510-c347b4170224';
  rec record;
  f record;
  i int;
  n int;
begin
  select id, center_lat, center_lng into f from farms where code = 'FERM-12';
  if f.id is null then raise notice 'FERM-12 missing, skipping'; return; end if;

  for rec in select id, farm_id from cattle
             where tag_code in ('YT-008000','YT-008001','YT-008002','YT-008003','YT-008004')
  loop
    n := 2;                            -- keep the demo data minimal
    for i in 1..n loop
      insert into scan_events
        (client_uuid, farm_id, cattle_id, scanned_by, method,
         lat, lng, accuracy_m, scanned_at, was_offline)
      values
        (gen_random_uuid(), rec.farm_id, rec.id, u_bat, 'nfc',
         f.center_lat + (random() - 0.5) * 0.055,     -- ~3km spread
         f.center_lng + (random() - 0.5) * 0.075,
         8 + random() * 20,
         now() - (random() * interval '20 days'),
         false);
    end loop;
  end loop;

  raise notice 'Demo scan positions generated for the map.';
end $$;

-- ============================================================
-- END v8
-- ============================================================
