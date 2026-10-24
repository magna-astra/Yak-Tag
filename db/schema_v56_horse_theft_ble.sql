-- ============================================================
-- YAK-TAG — schema v56: horses stage 2 (theft protection) + BLE tags
--
-- Owner's choices (2026-10-24, NEXT_SESSION 3zc):
--  · anyone can check a horse by chip, national (MGL) or tag number
--    (check.html). A normal horse: "registered, not reported lost" +
--    photo, зүс, age/sex, breed and the call button if the owner set a
--    phone — never the owner's name. A lost / stolen horse: a warning,
--    the photos (brand too) and "I saw this horse".
--  · the owner gets a Telegram message on EVERY check (at most one per
--    10 minutes per chat), with the place when the checker allows GPS.
--  · a public list of lost / stolen horses; the owner chooses per report
--    (on by default). The brand (тамга) photo is shown only there and
--    only while the horse is lost / stolen.
--  · BLE: our own beacons. A horse may carry one; a phone that finds it
--    nearby logs an encounter (scan_events.method = 'ble') with GPS.
--
-- Run in the Tokyo project (mjijgxfmkgtxmpbmshtl) after v55. Safe to
-- run twice. Nothing changes for cattle (report_lost keeps working with
-- its two old arguments).
-- ============================================================

do $$
begin
  if to_regprocedure('public.set_horse_details(uuid,text,text,boolean,text[],text)') is null
     or to_regprocedure('public.scan_caller_hash()') is null
     or to_regprocedure('public.tg_send(bigint,text)') is null then
    raise exception 'Run db/schema_v55_horses.sql first (or wrong database: open the Tokyo project mjijgxfmkgtxmpbmshtl).';
  end if;
end $$;

-- ---------- 1. columns ----------
alter table public.cattle
  add column if not exists lost_public       boolean not null default true,   -- in the public lost list
  add column if not exists public_brand_path text,                           -- cattle-public copy of the тамга photo
  add column if not exists ble_name          text;                           -- the BLE beacon's name

alter table public.cattle drop constraint if exists cattle_ble_name_check;
alter table public.cattle add constraint cattle_ble_name_check
  check (ble_name is null or length(ble_name) between 1 and 40);
create unique index if not exists cattle_ble_name_key on public.cattle (lower(ble_name)) where ble_name is not null;

-- a phone that finds the beacon nearby: an encounter like an NFC read
do $$
declare r record;
begin
  for r in select conname from pg_constraint
            where conrelid = 'public.scan_events'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%method%'
  loop
    execute format('alter table public.scan_events drop constraint %I', r.conname);
  end loop;
end $$;
alter table public.scan_events add constraint scan_events_method_check
  check (method in ('nfc', 'qr', 'uhf', 'manual', 'ble'));

-- ---------- 2. every check of a horse ----------
create table if not exists public.horse_checks (
  id          bigserial primary key,
  cattle_id   uuid references public.cattle(id) on delete cascade,   -- null: nothing found
  query_kind  text not null check (query_kind in ('chip', 'national_id', 'tag', 'list')),
  found       boolean not null,
  was_lost    boolean not null default false,
  seen        boolean not null default false,        -- "I saw this horse"
  lat         double precision,
  lng         double precision,
  accuracy_m  double precision,
  note        text,
  finder_phone text,
  caller_hash text,
  at          timestamptz not null default now()
);
create index if not exists horse_checks_cattle on public.horse_checks (cattle_id, at desc);
create index if not exists horse_checks_at on public.horse_checks (at);
alter table public.horse_checks enable row level security;
revoke all on table public.horse_checks from anon, authenticated;
grant select on table public.horse_checks to authenticated;
-- who may see an animal (cattle's own rules) sees its checks
drop policy if exists horse_checks_read on public.horse_checks;
create policy horse_checks_read on public.horse_checks for select to authenticated
  using (cattle_id is not null and exists (select 1 from public.cattle c where c.id = horse_checks.cattle_id));

-- ---------- 3. lost or stolen, public or not ----------
-- (the old two-argument version is replaced; calls with p_cattle_id +
-- p_note still work through the defaults)
drop function if exists public.report_lost(uuid, text);
create or replace function public.report_lost(
  p_cattle_id uuid,
  p_note      text,
  p_stolen    boolean default false,
  p_public    boolean default true
) returns void language plpgsql security definer set search_path = public as $$
declare c record;
begin
  select * into c from cattle where id = p_cattle_id;
  if not found then raise exception 'Animal not found'; end if;

  if not coalesce(is_super()
          or (my_role() = 'farm_admin' and c.farm_id = my_farm())
          or (my_role() = 'herder' and c.owner_id = auth.uid()), false) then
    raise exception 'Not allowed';
  end if;

  update cattle
     set reported_lost_at = now(), lost_note = nullif(left(trim(coalesce(p_note, '')), 300), ''),
         status = case when coalesce(p_stolen, false) then 'stolen' else 'lost' end,
         lost_public = coalesce(p_public, true)
   where id = p_cattle_id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (c.farm_id, auth.uid(), 'report_lost', 'cattle', p_cattle_id,
          jsonb_build_object('note', p_note, 'stolen', coalesce(p_stolen, false), 'public', coalesce(p_public, true)));
end $$;
revoke all on function public.report_lost(uuid, text, boolean, boolean) from public, anon;
grant execute on function public.report_lost(uuid, text, boolean, boolean) to authenticated;

-- ---------- 4. the brand photo's public copy (shown only while lost) ----------
create or replace function public.set_public_brand(p_cattle_id uuid, p_path text)
returns void language plpgsql security definer set search_path = public as $$
declare c record;
begin
  select * into c from cattle where id = p_cattle_id;
  if not found then raise exception 'Animal not found'; end if;
  if not coalesce(is_super()
          or (my_role() = 'farm_admin' and c.farm_id = my_farm())
          or (my_role() = 'herder' and c.owner_id = auth.uid()), false) then
    raise exception 'Not allowed';
  end if;
  -- only a file of this animal's own folder
  if p_path is not null and p_path not like 'farm-' || c.farm_id || '/cow-' || c.id || '/%' then
    raise exception 'Not allowed';
  end if;
  update cattle set public_brand_path = p_path where id = p_cattle_id;
  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (c.farm_id, auth.uid(), 'set_public_brand', 'cattle', p_cattle_id, jsonb_build_object('path', p_path));
end $$;
revoke all on function public.set_public_brand(uuid, text) from public, anon;
grant execute on function public.set_public_brand(uuid, text) to authenticated;

-- ---------- 5. BLE beacon on an animal ----------
create or replace function public.set_ble_tag(p_cattle_id uuid, p_ble_name text)
returns void language plpgsql security definer set search_path = public as $$
declare
  c      record;
  v_name text := nullif(trim(coalesce(p_ble_name, '')), '');
begin
  select * into c from cattle where id = p_cattle_id;
  if not found then raise exception 'Мал олдсонгүй.'; end if;
  if not coalesce(is_super()
          or (my_role() = 'farm_admin' and c.farm_id = my_farm())
          or (my_role() = 'herder' and c.owner_id = auth.uid()), false) then
    raise exception 'Энэ үйлдлийг хийх эрхгүй.';
  end if;
  if v_name is not null and length(v_name) > 40 then raise exception 'BLE тагийн нэр 40 тэмдэгтээс ихгүй.'; end if;
  if v_name is not null and exists (select 1 from cattle where lower(ble_name) = lower(v_name) and id <> c.id) then
    raise exception 'Энэ BLE таг өөр малд холбогдсон байна.';
  end if;
  update cattle set ble_name = v_name where id = c.id;
  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (c.farm_id, auth.uid(), 'set_ble_tag', 'cattle', c.id, jsonb_build_object('ble_name', v_name));
end $$;
revoke all on function public.set_ble_tag(uuid, text) from public, anon;
grant execute on function public.set_ble_tag(uuid, text) to authenticated;

-- ---------- 6. Telegram: a horse was checked / seen ----------
-- kind: 'check' (owner only), 'lost_check' and 'seen' (owner, the farm's
-- admins, its Админ, super admins — as a lost-animal tap)
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
  return n;                             -- an alert never breaks the check itself
end $$;
revoke all on function public.tg_alert_horse(uuid, text, double precision, double precision, double precision, text, text)
  from public, anon, authenticated;

-- ---------- 7. per-visitor limit (lookup_rate, its own key) ----------
create or replace function public.horse_check_limit(p_what text, p_per_hour int)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_caller text := scan_caller_hash();
  v_n      int;
begin
  if v_caller is null then return null; end if;
  insert into lookup_rate as lr (caller_hash, hour, n)
  values (p_what || ':' || v_caller, date_trunc('hour', now()), 1)
  on conflict (caller_hash, hour) do update set n = lr.n + 1
  returning lr.n into v_n;
  if v_n > p_per_hour then
    raise exception 'Хэт олон удаа шалгалаа. 1 цагийн дараа дахин оролдоно уу.';
  end if;
  return v_caller;
end $$;
revoke all on function public.horse_check_limit(text, integer) from public, anon, authenticated;

-- what a stranger may see of a horse (never the owner's name)
create or replace function public.public_horse_card(c public.cattle, p_lost boolean)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'ref', c.id,
    'status', case when p_lost then (case when c.status = 'stolen' then 'stolen' else 'lost' end) else 'ok' end,
    'sex', c.sex, 'birth_year', c.birth_year, 'castrated', c.castrated,
    'breed', c.breed, 'colour', c.colour, 'markings', c.markings,
    'photo_path', c.public_photo_path,
    'brand_path', case when p_lost and c.lost_public then c.public_brand_path end,
    'has_phone', c.contact_phone is not null, 'phone', c.contact_phone,
    'reported_lost_at', case when p_lost then c.reported_lost_at end,
    'lost_note', case when p_lost and c.lost_public then c.lost_note end)
$$;
revoke all on function public.public_horse_card(public.cattle, boolean) from public, anon, authenticated;

-- ---------- 8. the public check ----------
create or replace function public.public_horse_check(
  p_query    text,
  p_lat      double precision default null,
  p_lng      double precision default null,
  p_accuracy double precision default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  q       text := upper(regexp_replace(coalesce(p_query, ''), '[\s-]', '', 'g'));
  v_kind  text;
  v_val   text;
  m       text[];
  c       public.cattle;
  v_found boolean;
  v_lost  boolean := false;
  v_caller text;
begin
  v_caller := horse_check_limit('hchk', 30);

  if q ~ '^[0-9]{15}$' then v_kind := 'chip'; v_val := q;
  elsif q ~ '^MGL[0-9]{10}$' then v_kind := 'national_id'; v_val := q;
  elsif q ~ '^[0-9]{1,6}$' then v_kind := 'tag'; v_val := 'YT-' || lpad(q, 6, '0');
  else
    m := regexp_match(q, '^([A-Z]{1,6})([0-9]{1,6})$');
    if m is null then
      raise exception 'Чип (15 оронтой), улсын дугаар (MGL…) эсвэл тагийн дугаар (YT-…) оруулна уу.';
    end if;
    v_kind := 'tag'; v_val := m[1] || '-' || lpad(m[2], 6, '0');
  end if;

  select ca.* into c
  from cattle ca join farms f on f.id = ca.farm_id
  where ca.species = 'horse' and f.status = 'active'
    and case v_kind when 'chip' then ca.chip_no = v_val
                    when 'national_id' then ca.national_id = v_val
                    else ca.tag_code = v_val end
    and not exists (select 1 from tags tg where tg.id = ca.tag_id and tg.paused_at is not null);
  v_found := found;
  if v_found then
    v_lost := c.reported_lost_at is not null or c.status in ('lost', 'stolen');
  end if;

  -- keep every check of a found horse; unknown numbers only up to 500 an hour
  if v_found or (select count(*) from horse_checks hc where not hc.found and hc.at > now() - interval '1 hour') < 500 then
    insert into horse_checks (cattle_id, query_kind, found, was_lost, lat, lng, accuracy_m, caller_hash)
    values (case when v_found then c.id end, v_kind, v_found, v_lost, p_lat, p_lng, p_accuracy, v_caller);
  end if;
  if random() < 0.01 then
    delete from horse_checks hc where not hc.found and hc.at < now() - interval '30 days';
    delete from lookup_rate where hour < now() - interval '2 days';
  end if;

  if not v_found then return jsonb_build_object('found', false, 'kind', v_kind); end if;

  perform tg_alert_horse(c.id, case when v_lost then 'lost_check' else 'check' end, p_lat, p_lng, p_accuracy);
  return public_horse_card(c, v_lost) || jsonb_build_object('found', true, 'kind', v_kind);
end $$;

-- ---------- 9. "I saw this horse" (lost / stolen only) ----------
create or replace function public.public_horse_seen(
  p_ref      uuid,
  p_lat      double precision default null,
  p_lng      double precision default null,
  p_accuracy double precision default null,
  p_note     text default null,
  p_phone    text default null
) returns boolean language plpgsql security definer set search_path = public as $$
declare
  c        public.cattle;
  v_caller text;
  v_phone  text := nullif(left(trim(coalesce(p_phone, '')), 24), '');
begin
  v_caller := horse_check_limit('hseen', 10);
  if v_phone is not null and v_phone !~ '^\+?[0-9][0-9 ()-]{5,22}$' then
    raise exception 'Утасны дугаар буруу. Зөвхөн тоо оруулна уу.';
  end if;
  select ca.* into c from cattle ca join farms f on f.id = ca.farm_id
   where ca.id = p_ref and ca.species = 'horse' and f.status = 'active'
     and (ca.reported_lost_at is not null or ca.status in ('lost', 'stolen'));
  if not found then return false; end if;

  insert into horse_checks (cattle_id, query_kind, found, was_lost, seen, lat, lng, accuracy_m, note, finder_phone, caller_hash)
  values (c.id, 'list', true, true, true, p_lat, p_lng, p_accuracy,
          nullif(left(trim(coalesce(p_note, '')), 300), ''), v_phone, v_caller);
  perform tg_alert_horse(c.id, 'seen', p_lat, p_lng, p_accuracy,
                         nullif(left(trim(coalesce(p_note, '')), 300), ''), v_phone);
  return true;
end $$;

-- ---------- 10. the public list of lost / stolen horses ----------
create or replace function public.public_lost_horses(
  p_colour text default null,
  p_sex    text default null,
  p_limit  integer default 30,
  p_offset integer default 0
) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform horse_check_limit('hlist', 120);
  return coalesce((
    select jsonb_agg(public_horse_card(ca, true) order by ca.reported_lost_at desc nulls last, ca.id)
    from cattle ca
    where ca.id in (
      select c2.id from cattle c2 join farms f on f.id = c2.farm_id
       where c2.species = 'horse' and f.status = 'active' and c2.lost_public
         and (c2.reported_lost_at is not null or c2.status in ('lost', 'stolen'))
         and (p_colour is null or c2.colour = p_colour)
         and (p_sex is null or c2.sex = p_sex)
         and not exists (select 1 from tags tg where tg.id = c2.tag_id and tg.paused_at is not null)
       order by c2.reported_lost_at desc nulls last, c2.id
       limit least(greatest(coalesce(p_limit, 30), 1), 60) offset greatest(coalesce(p_offset, 0), 0))
  ), '[]'::jsonb);
end $$;

revoke all on function public.public_horse_check(text, double precision, double precision, double precision) from public;
revoke all on function public.public_horse_seen(uuid, double precision, double precision, double precision, text, text) from public;
revoke all on function public.public_lost_horses(text, text, integer, integer) from public;
grant execute on function public.public_horse_check(text, double precision, double precision, double precision) to anon, authenticated;
grant execute on function public.public_horse_seen(uuid, double precision, double precision, double precision, text, text) to anon, authenticated;
grant execute on function public.public_lost_horses(text, text, integer, integer) to anon, authenticated;

notify pgrst, 'reload schema';
