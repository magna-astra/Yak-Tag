-- ============================================================
-- YAK-TAG — schema patch v7
-- The public tap page: what a stranger sees, and what the
-- owner learns when a stranger taps.
-- ============================================================

-- ============================================================
-- 1. CONTACT DETAILS + LOST STATUS
-- ============================================================
alter table profiles
  add column if not exists public_phone text,      -- shown to finders
  add column if not exists show_phone boolean not null default true;

alter table cattle
  add column if not exists reported_lost_at timestamptz,
  add column if not exists lost_note text;

-- seed the demo farmer's contact so the call button works
update profiles
   set public_phone = phone
 where public_phone is null and phone is not null;

-- ============================================================
-- 2. PUBLIC LOOKUP
--
-- security definer so an anonymous visitor can call it, but it
-- returns ONLY what a finder needs. No milk data, no health
-- history, no GPS trail, no owner email.
--
-- Registered location is the farm's home point — deliberately
-- NOT the animal's last GPS position. Publishing live positions
-- of livestock would be an aid to thieves, not a defence.
-- ============================================================
create or replace function public_tag_lookup(p_tag_code text)
returns table (
  tag_code        text,
  farm_name       text,
  farm_aimag      text,
  farm_soum       text,
  owner_name      text,
  owner_phone     text,
  sex             text,
  birth_year      int,
  breed           text,
  status          text,
  is_lost         boolean,
  lost_note       text,
  registered_at   timestamptz,
  registered_lat  numeric,
  registered_lng  numeric,
  photo_path      text
) language sql security definer set search_path = public as $$
  select
    c.tag_code,
    f.name,
    f.aimag,
    f.soum,
    p.full_name,
    case when p.show_phone then p.public_phone else null end,
    c.sex,
    c.birth_year,
    c.breed,
    c.status,
    (c.reported_lost_at is not null or c.status in ('lost','stolen')),
    c.lost_note,
    c.created_at,
    c.reg_lat,
    c.reg_lng,
    (select ph.storage_path from cattle_photos ph
      where ph.cattle_id = c.id and ph.kind = 'profile'
      order by ph.taken_at desc limit 1)
  from cattle c
  join farms f    on f.id = c.farm_id
  join profiles p on p.id = c.owner_id
  where c.tag_code = p_tag_code
    and f.status = 'active';
$$;

grant execute on function public_tag_lookup(text) to anon, authenticated;

-- ============================================================
-- 3. SCAN ALERTS
--
-- Every public tap is recorded. The owner sees these in their
-- dashboard. For a stolen animal, a tap by a stranger is the
-- single most useful signal the system can produce — someone
-- has the animal in their hands, right now, somewhere.
-- ============================================================
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
  contacted    boolean not null default false   -- did they press call?
);
create index if not exists public_scans_cattle_idx on public_scans(cattle_id, scanned_at desc);
create index if not exists public_scans_farm_idx   on public_scans(farm_id, scanned_at desc);

alter table public_scans enable row level security;

-- anyone may record a scan (that is the point), nobody anonymous may read them
create policy public_scan_insert on public_scans for insert
  to anon, authenticated with check (true);

create policy public_scan_read on public_scans for select
  using (
    is_super()
    or (my_role() = 'farm_admin' and farm_id = my_farm())
    or (my_role() = 'herder' and exists (
          select 1 from cattle c
          where c.id = public_scans.cattle_id and c.owner_id = auth.uid()))
  );

-- record a public scan without exposing internal ids
create or replace function record_public_scan(
  p_tag_code   text,
  p_lat        numeric default null,
  p_lng        numeric default null,
  p_accuracy   numeric default null,
  p_user_agent text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  c record;
  v_id uuid;
begin
  select id, farm_id, status, reported_lost_at into c
  from cattle where tag_code = p_tag_code;
  if not found then return null; end if;

  insert into public_scans (cattle_id, farm_id, lat, lng, accuracy_m, user_agent, was_lost)
  values (c.id, c.farm_id, p_lat, p_lng, p_accuracy, p_user_agent,
          (c.reported_lost_at is not null or c.status in ('lost','stolen')))
  returning id into v_id;

  return v_id;
end $$;

grant execute on function record_public_scan(text, numeric, numeric, numeric, text)
  to anon, authenticated;

-- mark that the finder pressed the call button
create or replace function mark_scan_contacted(p_scan_id uuid)
returns void language sql security definer set search_path = public as $$
  update public_scans set contacted = true where id = p_scan_id;
$$;

grant execute on function mark_scan_contacted(uuid) to anon, authenticated;

-- ============================================================
-- 4. REPORT LOST / FOUND — for the owner's dashboard
-- ============================================================
create or replace function report_lost(p_cattle_id uuid, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare c record;
begin
  select * into c from cattle where id = p_cattle_id;
  if not found then raise exception 'Animal not found'; end if;

  if not (is_super()
          or (my_role() = 'farm_admin' and c.farm_id = my_farm())
          or (my_role() = 'herder' and c.owner_id = auth.uid())) then
    raise exception 'Not allowed';
  end if;

  update cattle
     set reported_lost_at = now(), lost_note = p_note, status = 'lost'
   where id = p_cattle_id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (c.farm_id, auth.uid(), 'report_lost', 'cattle', p_cattle_id,
          jsonb_build_object('note', p_note));
end $$;

create or replace function report_found(p_cattle_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare c record;
begin
  select * into c from cattle where id = p_cattle_id;
  if not found then raise exception 'Animal not found'; end if;

  if not (is_super()
          or (my_role() = 'farm_admin' and c.farm_id = my_farm())
          or (my_role() = 'herder' and c.owner_id = auth.uid())) then
    raise exception 'Not allowed';
  end if;

  update cattle
     set reported_lost_at = null, lost_note = null, status = 'active'
   where id = p_cattle_id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (c.farm_id, auth.uid(), 'report_found', 'cattle', p_cattle_id, '{}'::jsonb);
end $$;

-- ============================================================
-- 5. VACCINATION — explicit given/next dates
-- ============================================================
alter table health_events
  add column if not exists given_on date,
  add column if not exists vaccine_name text;

update health_events
   set given_on = occurred_at::date
 where kind = 'vaccination' and given_on is null;

-- ============================================================
-- CHECK
--   select * from public_tag_lookup('YT-008000');
-- ============================================================
