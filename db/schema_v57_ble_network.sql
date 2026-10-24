-- ============================================================
-- YAK-TAG — schema v57: our own BLE listener network (step 2)
--
-- Protocol: BLE_TAG_SPEC.md. A BLE tag is heard ~50–100 m away, so a
-- horse's place comes from OUR listeners — "like an AirTag", no
-- subscriptions, all software ours:
--   · phones with the YAK-TAG app: ble_report() — any YAK-TAG tag they
--     hear, also other people's horses (the crowd), with the phone's GPS;
--   · ESP32 boxes at wells / winter camps: ble_gateway_report() with the
--     box's secret key; the box's saved place is used.
-- Each sighting (one per horse per listener per 10 minutes) goes into
-- ble_sightings, which is now part of all_scans: "Сүүлд харагдсан" and
-- the dashboard map move by themselves. A lost / stolen horse that is
-- heard → Telegram alert (tg_alert_horse 'ble').
--
-- Run in the Tokyo project (mjijgxfmkgtxmpbmshtl) after v56. Safe to
-- run twice. Horses (and so this) stay hidden until launch (config.js).
-- ============================================================

do $$
begin
  if to_regprocedure('public.set_ble_tag(uuid,text)') is null
     or to_regprocedure('public.tg_alert_horse(uuid,text,double precision,double precision,double precision,text,text)') is null then
    raise exception 'Run db/schema_v56_horse_theft_ble.sql first (or wrong database: open the Tokyo project mjijgxfmkgtxmpbmshtl).';
  end if;
end $$;

-- ---------- 1. the tag's last report on the animal ----------
alter table public.cattle
  add column if not exists ble_battery  smallint,          -- % from the tag (protocol v1), null = unknown
  add column if not exists ble_heard_at timestamptz;       -- last time any listener heard it

-- ---------- 2. listener boxes (ESP32 at a well / winter camp) ----------
create table if not exists public.ble_gateways (
  id             uuid primary key default gen_random_uuid(),
  farm_id        uuid not null references public.farms(id) on delete cascade,
  name           text not null check (length(name) between 1 and 60),
  key_hash       text not null unique,                     -- sha256 of the box's secret key
  lat            double precision,
  lng            double precision,
  created_by     uuid references public.profiles(id) on delete set null,
  created_at     timestamptz not null default now(),
  last_report_at timestamptz
);
alter table public.ble_gateways enable row level security;
revoke all on table public.ble_gateways from anon, authenticated;
grant select (id, farm_id, name, lat, lng, created_at, last_report_at) on public.ble_gateways to authenticated;
drop policy if exists ble_gateways_read on public.ble_gateways;
create policy ble_gateways_read on public.ble_gateways for select to authenticated
  using ((select is_super()) or farm_id = (select my_farm())
         or farm_id = any ((select public.admin_farm_ids())::uuid[]));

-- ---------- 3. sightings ----------
create table if not exists public.ble_sightings (
  id          bigserial primary key,
  cattle_id   uuid not null references public.cattle(id) on delete cascade,
  farm_id     uuid not null,                               -- the animal's farm
  ble_name    text,
  source      text not null check (source in ('app', 'gateway')),
  gateway_id  uuid references public.ble_gateways(id) on delete set null,
  reporter    uuid references public.profiles(id) on delete set null,
  scanned_at  timestamptz not null,
  lat         double precision,
  lng         double precision,
  accuracy_m  numeric,
  rssi        smallint,
  battery     smallint,
  at          timestamptz not null default now()
);
create index if not exists ble_sightings_cattle on public.ble_sightings (cattle_id, scanned_at desc);
create index if not exists ble_sightings_at on public.ble_sightings (at);
alter table public.ble_sightings enable row level security;
revoke all on table public.ble_sightings from anon, authenticated;
grant select on table public.ble_sightings to authenticated;
-- who may see the animal sees where it was heard
drop policy if exists ble_sightings_read on public.ble_sightings;
create policy ble_sightings_read on public.ble_sightings for select to authenticated
  using (exists (select 1 from public.cattle c where c.id = ble_sightings.cattle_id));

-- ---------- 4. "last seen" everywhere: a third source ----------
create or replace view public.all_scans as
select cattle_id, farm_id, scanned_at, lat, lng, accuracy_m,
       'app'::text as source, scanned_by as actor
from public.scan_events
union all
select cattle_id, farm_id, scanned_at, lat, lng, accuracy_m,
       'public'::text as source, null::uuid as actor
from public.public_scans
union all
select cattle_id, farm_id, scanned_at, lat, lng, accuracy_m,
       'ble'::text as source, reporter as actor
from public.ble_sightings;
alter view public.all_scans set (security_invoker = on);

-- ---------- 5. alerts: a lost horse's tag was heard ----------
-- Same as v56, plus kind 'ble'.
create or replace function public.tg_alert_horse(
  p_cattle_id uuid, p_kind text,
  p_lat double precision, p_lng double precision, p_accuracy double precision,
  p_note text default null, p_phone text default null
) returns integer language plpgsql security definer set search_path = public as $$
declare
  c      record;
  r      record;
  v_site text := coalesce(app_secret('site_url'), 'https://yaktag.org');
  v_txt  text;
  v_wait interval := case p_kind when 'seen' then interval '1 minute' else interval '10 minutes' end;
  n      int := 0;
begin
  if app_secret('telegram_token') is null then return 0; end if;
  select ca.id, ca.tag_code, ca.chip_no, ca.national_id, ca.farm_id, ca.owner_id, ca.breed, ca.colour, ca.status
    into c from cattle ca where ca.id = p_cattle_id;
  if not found then return 0; end if;

  v_txt := case p_kind
             when 'seen'       then '👁 АЛГА БОЛСОН АДУУГ ХАРСАН ГЭЖ МЭДЭГДЛЭЭ'
             when 'lost_check' then '⚠ АЛГА БОЛСОН АДУУГ ШАЛГАЛАА'
             when 'ble'        then '📡 АЛГА БОЛСОН АДУУНЫ BLE ТАГ СОНСОГДЛОО'
             else '🔎 Таны адууг дугаараар нь шалгалаа' end || E'\n\n'
        || coalesce(c.tag_code, c.national_id, 'чип …' || right(c.chip_no, 6), 'таггүй адуу')
        || coalesce(' · ' || c.breed, '') || coalesce(' · ' || c.colour, '') || E'\n'
        || 'Хэзээ: ' || to_char(now() at time zone 'Asia/Ulaanbaatar', 'YYYY/MM/DD HH24:MI') || E'\n'
        || case when p_lat is not null and p_lng is not null
                then 'Хаана: https://maps.google.com/?q=' || round(p_lat::numeric, 6) || ',' || round(p_lng::numeric, 6)
                     || coalesce(' (±' || round(p_accuracy)::text || ' м)', '')
                else 'Хаана: байршил тодорхойгүй (шалгасан хүн байршлаа зөвшөөрөөгүй)' end
        || coalesce(E'\n' || 'Тэмдэглэл: ' || left(p_note, 300), '')
        || coalesce(E'\n' || 'Харсан хүний утас: ' || left(p_phone, 24), '')
        || case when p_kind = 'check'
                then E'\n\n' || 'Та шалгуулаагүй бол — хэн нэгэн таны адууг зарах гэж байж магадгүй.'
                else '' end
        || E'\n\n' || 'Дэлгэрэнгүй: ' || v_site || '/cow.html?'
        || case when c.tag_code is not null then 'tag=' || c.tag_code else 'id=' || c.id end;

  for r in
    select distinct l.chat_id
    from telegram_links l
    join profiles p on p.id = l.profile_id and p.status = 'active'
    where p.id = c.owner_id
       or (p_kind <> 'check' and (
             (p.role = 'farm_admin' and p.farm_id = c.farm_id)
          or (p.role = 'admin' and exists (select 1 from farms af where af.id = c.farm_id and af.created_by = p.id))
          or p.role = 'super_admin'))
  loop
    continue when exists (
      select 1 from notify_log
      where cattle_id = c.id and chat_id = r.chat_id and kind = 'horse_' || p_kind
        and sent_at > now() - v_wait);
    insert into notify_log (cattle_id, chat_id, kind, request_id)
    values (c.id, r.chat_id, 'horse_' || p_kind, tg_send(r.chat_id, v_txt));
    n := n + 1;
  end loop;
  return n;
exception when others then
  return n;                             -- an alert never breaks what triggered it
end $$;
revoke all on function public.tg_alert_horse(uuid, text, double precision, double precision, double precision, text, text)
  from public, anon, authenticated;

-- ---------- 6. one place that takes in what a listener heard ----------
create or replace function public.ble_ingest(
  p_source text, p_gateway uuid, p_reporter uuid,
  p_lat double precision, p_lng double precision, p_accuracy double precision,
  p_items jsonb
) returns integer language plpgsql security definer set search_path = public as $$
declare
  it      jsonb;
  c       record;
  v_name  text;
  v_seen  timestamptz;
  v_bat   int;
  v_rssi  int;
  n       int := 0;
begin
  if jsonb_typeof(p_items) is distinct from 'array' then raise exception 'p_items: a list is needed'; end if;
  if jsonb_array_length(p_items) > 50 then raise exception 'Нэг удаад 50-аас ихгүй.'; end if;

  for it in select * from jsonb_array_elements(p_items) loop
    v_name := nullif(trim(coalesce(it->>'name', '')), '');
    continue when v_name is null or length(v_name) > 40;
    select ca.id, ca.farm_id, ca.status, ca.reported_lost_at into c
      from cattle ca where lower(ca.ble_name) = lower(v_name);
    continue when not found;

    -- the tag's own time; a wrong phone clock falls back to now
    begin v_seen := (it->>'seen_at')::timestamptz; exception when others then v_seen := null; end;
    if v_seen is null or v_seen > now() + interval '5 minutes' or v_seen < now() - interval '1 day' then
      v_seen := now();
    end if;
    begin v_bat := (it->>'battery')::int; exception when others then v_bat := null; end;
    if v_bat is not null and (v_bat < 0 or v_bat > 100) then v_bat := null; end if;
    begin v_rssi := (it->>'rssi')::int; exception when others then v_rssi := null; end;
    if v_rssi is not null and (v_rssi < -127 or v_rssi > 20) then v_rssi := null; end if;

    -- the tag's battery and "heard" time, from any listener
    update cattle set ble_battery = coalesce(v_bat, ble_battery),
                      ble_heard_at = greatest(coalesce(ble_heard_at, v_seen), v_seen)
     where id = c.id;

    -- one sighting per horse per listener per 10 minutes
    continue when exists (
      select 1 from ble_sightings s
       where s.cattle_id = c.id
         and (case when p_gateway is not null then s.gateway_id = p_gateway else s.reporter = p_reporter end)
         and s.scanned_at > v_seen - interval '10 minutes' and s.scanned_at < v_seen + interval '10 minutes');

    insert into ble_sightings (cattle_id, farm_id, ble_name, source, gateway_id, reporter,
                               scanned_at, lat, lng, accuracy_m, rssi, battery)
    values (c.id, c.farm_id, v_name, p_source, p_gateway, p_reporter,
            v_seen, p_lat, p_lng, p_accuracy::numeric, v_rssi, v_bat);
    n := n + 1;

    if c.reported_lost_at is not null or c.status in ('lost', 'stolen') then
      perform tg_alert_horse(c.id, 'ble', p_lat, p_lng, p_accuracy);
    end if;
  end loop;

  if random() < 0.01 then
    delete from ble_sightings where at < now() - interval '180 days';
  end if;
  return n;
end $$;
revoke all on function public.ble_ingest(text, uuid, uuid, double precision, double precision, double precision, jsonb)
  from public, anon, authenticated;

-- an hourly counter (lookup_rate, its own key) for listeners
create or replace function public.ble_limit(p_key text, p_per_hour int)
returns void language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  insert into lookup_rate as lr (caller_hash, hour, n)
  values (p_key, date_trunc('hour', now()), 1)
  on conflict (caller_hash, hour) do update set n = lr.n + 1
  returning lr.n into v_n;
  if v_n > p_per_hour then raise exception 'Хэт олон удаа илгээлээ. 1 цагийн дараа дахин оролдоно уу.'; end if;
end $$;
revoke all on function public.ble_limit(text, integer) from public, anon, authenticated;

-- ---------- 7. a phone reports (signed in; the crowd) ----------
create or replace function public.ble_report(
  p_lat      double precision,
  p_lng      double precision,
  p_accuracy double precision,
  p_items    jsonb
) returns integer language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Нэвтэрнэ үү.'; end if;
  if not exists (select 1 from profiles where id = auth.uid() and status = 'active') then
    raise exception 'Таны бүртгэл идэвхгүй байна. Админд хандана уу.';
  end if;
  perform ble_limit('bler:' || auth.uid(), 120);
  return ble_ingest('app', null, auth.uid(), p_lat, p_lng, p_accuracy, p_items);
end $$;

-- ---------- 8. a box at a well reports (no login: its secret key) ----------
create or replace function public.ble_gateway_report(p_key text, p_items jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare g record;
begin
  select * into g from ble_gateways
   where key_hash = encode(sha256(convert_to(coalesce(p_key, ''), 'UTF8')), 'hex');
  if not found then raise exception 'Unknown listener key'; end if;
  perform ble_limit('blegw:' || g.id, 120);
  update ble_gateways set last_report_at = now() where id = g.id;
  return ble_ingest('gateway', g.id, null, g.lat, g.lng, null, p_items);
end $$;

-- ---------- 9. adding / removing a box ----------
-- Adding: herder / farm admin on their farm; super admin: p_farm. The key
-- is shown ONCE (only its hash is kept) — it goes into the box's settings.
-- Removing: whoever added it, the farm admin, the super admin.
create or replace function public.ble_gateway_create(
  p_name text, p_lat double precision, p_lng double precision, p_farm uuid default null
) returns text language plpgsql security definer set search_path = public as $$
declare
  me     record;
  v_farm uuid;
  v_key  text := 'ytg_' || replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  v_id   uuid;
begin
  select id, role, farm_id into me from profiles where id = auth.uid() and status = 'active';
  if not found then raise exception 'Нэвтэрнэ үү.'; end if;
  v_farm := case when me.role = 'super_admin' then p_farm
                 when me.role in ('herder', 'farm_admin') then me.farm_id end;
  if v_farm is null then raise exception 'Ферм тодорхойгүй. Малчин эсвэл ферм админ нэмнэ.'; end if;
  if nullif(trim(coalesce(p_name, '')), '') is null then raise exception 'Нэр өгнө үү (жишээ: Хойд худаг).'; end if;
  if (select count(*) from ble_gateways where farm_id = v_farm) >= 50 then
    raise exception 'Нэг фермд 50-аас олон сонсогч нэмэх боломжгүй.';
  end if;
  insert into ble_gateways (farm_id, name, key_hash, lat, lng, created_by)
  values (v_farm, left(trim(p_name), 60), encode(sha256(convert_to(v_key, 'UTF8')), 'hex'), p_lat, p_lng, me.id)
  returning id into v_id;
  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (v_farm, me.id, 'ble_gateway_create', 'ble_gateways', v_id, jsonb_build_object('name', p_name, 'lat', p_lat, 'lng', p_lng));
  return v_key;
end $$;

create or replace function public.ble_gateway_delete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me record; g record;
begin
  select id, role, farm_id into me from profiles where id = auth.uid() and status = 'active';
  if not found then raise exception 'Нэвтэрнэ үү.'; end if;
  select * into g from ble_gateways where id = p_id;
  if not found then raise exception 'Сонсогч олдсонгүй.'; end if;
  -- the one who added it, the farm's admin, the super admin
  if not (me.role = 'super_admin' or (me.role = 'farm_admin' and me.farm_id = g.farm_id) or g.created_by = me.id) then
    raise exception 'Энэ үйлдлийг хийх эрхгүй.';
  end if;
  delete from ble_gateways where id = p_id;
  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (g.farm_id, me.id, 'ble_gateway_delete', 'ble_gateways', p_id, jsonb_build_object('name', g.name));
end $$;

revoke all on function public.ble_report(double precision, double precision, double precision, jsonb) from public, anon;
revoke all on function public.ble_gateway_report(text, jsonb) from public;
revoke all on function public.ble_gateway_create(text, double precision, double precision, uuid) from public, anon;
revoke all on function public.ble_gateway_delete(uuid) from public, anon;
grant execute on function public.ble_report(double precision, double precision, double precision, jsonb) to authenticated;
grant execute on function public.ble_gateway_report(text, jsonb) to anon, authenticated;
grant execute on function public.ble_gateway_create(text, double precision, double precision, uuid) to authenticated;
grant execute on function public.ble_gateway_delete(uuid) to authenticated;

notify pgrst, 'reload schema';
