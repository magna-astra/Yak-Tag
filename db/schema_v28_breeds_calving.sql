-- ============================================================
-- YAK-TAG — schema patch v28
-- Species + breed dropdown, and pregnancy / calving records.
--
-- Yak-Tag covers COWS (үхэр — including yak and hainag) and HORSES
-- (адуу). Each animal gets a species and a breed from a fixed list,
-- or "Бусад" with the name typed in. The breed decides the expected
-- pregnancy length, so the expected calving date is right for a yak
-- (~258 days), not only for western cattle (~283).
--
-- Reproduction events follow the ICAR Animal Data Exchange (ADE)
-- standard's names and codes, so the data can be exported later:
--   insemination     — ADE Insemination (natural, run with bull, AI, embryo)
--   pregnancy_check  — ADE PregnancyCheck (method, result, foetal age)
--   calving          — ADE Parturition (calving ease 1–5, each calf's
--                      sex and birth status)
--   abortion         — ADE Abortion
--
-- Safe on the live project and safe to run twice. Existing animals
-- get species = null ("тодорхойгүй") — nothing is guessed; the owner
-- or an admin picks it. cattle_dashboard (and the map) are untouched.
-- ============================================================

-- ============================================================
-- 1. BREEDS
-- gestation_days = average pregnancy length used for the expected
-- date. It is only a starting point: every expected date can be
-- corrected, e.g. after a pregnancy check.
-- ============================================================
create table if not exists breeds (
  code           text primary key,
  species        text not null check (species in ('cattle', 'horse')),
  name_mn        text not null,
  gestation_days integer not null check (gestation_days between 100 and 450),
  is_other       boolean not null default false,   -- "Бусад": name typed by hand
  sort_order     integer not null default 100,
  active         boolean not null default true
);

insert into breeds (code, species, name_mn, gestation_days, is_other, sort_order) values
  ('mongol',        'cattle', 'Монгол үүлдэр',          283, false, 10),
  ('yak',           'cattle', 'Монгол сарлаг',          258, false, 20),
  ('hainag',        'cattle', 'Хайнаг',                 275, false, 30),
  ('selenge',       'cattle', 'Сэлэнгэ',                283, false, 40),
  ('dornod_red',    'cattle', 'Дорнод Монголын улаан',  283, false, 50),
  ('black_pied',    'cattle', 'Хар тарлан (Голштейн)',  280, false, 60),
  ('red_steppe',    'cattle', 'Талын улаан',            283, false, 70),
  ('simmental',     'cattle', 'Симментал',              285, false, 80),
  ('alatau',        'cattle', 'Алатау',                 285, false, 90),
  ('cattle_other',  'cattle', 'Бусад',                  283, true,  999),
  ('mongol_horse',  'horse',  'Монгол адуу',            340, false, 10),
  ('galshar',       'horse',  'Галшар',                 340, false, 20),
  ('jargalant',     'horse',  'Жаргалант',              340, false, 30),
  ('tes',           'horse',  'Тэс',                    340, false, 40),
  ('darkhad',       'horse',  'Дархад',                 340, false, 50),
  ('horse_other',   'horse',  'Бусад',                  340, true,  999)
on conflict (code) do nothing;          -- never overwrite later edits

alter table breeds enable row level security;
drop policy if exists breeds_read on breeds;
create policy breeds_read on breeds for select to authenticated using (true);

alter table cattle add column if not exists species    text;
alter table cattle add column if not exists breed_code text references breeds(code);
alter table cattle drop constraint if exists cattle_species_check;
alter table cattle add constraint cattle_species_check
  check (species is null or species in ('cattle', 'horse'));

create or replace function gestation_days(p_breed_code text, p_species text)
returns integer language sql stable as $$
  select coalesce(
    (select gestation_days from breeds where code = p_breed_code),
    case p_species when 'cattle' then 283 when 'horse' then 340 end)
$$;

-- ============================================================
-- 2. SET SPECIES / BREED (owner, farm admin, super admin)
-- ============================================================
create or replace function set_cattle_breed(
  p_cattle_id  uuid,
  p_breed_code text,
  p_breed_text text default null        -- the name, when "Бусад"
) returns void language plpgsql security definer set search_path = public as $$
declare
  c  record;
  b  record;
begin
  select id, farm_id, owner_id into c from cattle where id = p_cattle_id;
  if not found then raise exception 'Мал олдсонгүй.'; end if;
  if not (is_super()
          or (my_role() = 'farm_admin' and c.farm_id = my_farm())
          or (my_role() is not null and c.owner_id = auth.uid())) then
    raise exception 'Зөвхөн эзэмшигч эсвэл админ.';
  end if;

  select * into b from breeds where code = p_breed_code and active;
  if not found then raise exception 'Үүлдэр сонгоно уу.'; end if;
  if b.is_other and nullif(trim(p_breed_text), '') is null then
    raise exception '"Бусад" бол үүлдрийн нэрийг бичнэ үү.';
  end if;

  update cattle
     set species = b.species,
         breed_code = b.code,
         breed = case when b.is_other then trim(p_breed_text) else b.name_mn end
   where id = p_cattle_id;
end $$;

-- ============================================================
-- 3. REPRODUCTION EVENTS
-- Written only through record_repro_event (below); read under the
-- same rules as the animal: owner, own farm's admin, super admin.
-- ============================================================
create table if not exists repro_events (
  id              uuid primary key default gen_random_uuid(),
  farm_id         uuid not null references farms(id),
  cattle_id       uuid not null references cattle(id) on delete cascade,
  kind            text not null
                  check (kind in ('insemination', 'pregnancy_check', 'calving', 'abortion')),
  event_date      date not null,

  -- insemination — ADE InseminationType
  method          text check (method in ('natural', 'run_with_bull', 'ai', 'embryo')),
  sire_tag        text,
  sire_name       text,

  -- pregnancy check — ADE PregnancyMethodType / PregnancyResultType
  result          text check (result in ('pregnant', 'empty', 'unknown')),
  check_method    text check (check_method in ('echography', 'palpation', 'blood', 'milk', 'visual', 'other')),
  foetal_age_days integer check (foetal_age_days between 0 and 450),

  -- calving — ADE CalvingEaseType (INTERBEEF 1–5)
  calving_ease    smallint check (calving_ease between 1 and 5),

  expected_date   date,          -- insemination / pregnancy check: expected birth
  note            text,
  recorded_by     uuid references profiles(id),
  created_at      timestamptz not null default now()
);
create index if not exists repro_events_cattle_idx on repro_events (cattle_id, event_date desc, created_at desc);
create index if not exists repro_events_farm_idx   on repro_events (farm_id, expected_date);

-- One row per calf / foal — ADE ProgenyDetails
create table if not exists repro_calves (
  id              uuid primary key default gen_random_uuid(),
  event_id        uuid not null references repro_events(id) on delete cascade,
  sex             text not null check (sex in ('female', 'male')),
  birth_status    text not null default 'alive'
                  check (birth_status in ('alive', 'stillborn', 'died_later')),
  birth_weight_kg numeric(5,1) check (birth_weight_kg > 0 and birth_weight_kg < 150),
  calf_cattle_id  uuid references cattle(id) on delete set null   -- once the calf has its own tag
);
create index if not exists repro_calves_event_idx on repro_calves (event_id);

alter table repro_events enable row level security;
alter table repro_calves enable row level security;

drop policy if exists repro_events_read on repro_events;
create policy repro_events_read on repro_events for select using (
  is_super()
  or (my_role() = 'farm_admin' and farm_id = my_farm())
  or exists (select 1 from cattle c where c.id = repro_events.cattle_id
             and c.owner_id = auth.uid() and my_role() is not null));

drop policy if exists repro_calves_read on repro_calves;
create policy repro_calves_read on repro_calves for select using (
  exists (select 1 from repro_events e where e.id = repro_calves.event_id));  -- same rule, via the event

-- ============================================================
-- 4. RECORD AN EVENT
-- p_calves (calving only): [{"sex":"female","birth_status":"alive","birth_weight_kg":24}]
-- The expected date is computed unless given:
--   insemination     date + breed's pregnancy length
--   pregnancy_check  pregnant + foetal age -> check date - age + length;
--                    pregnant, no age      -> keep the latest insemination's date
-- ============================================================
create or replace function record_repro_event(
  p_cattle_id     uuid,
  p_kind          text,
  p_date          date,
  p_method        text default null,
  p_sire_tag      text default null,
  p_sire_name     text default null,
  p_result        text default null,
  p_check_method  text default null,
  p_foetal_age    integer default null,
  p_calving_ease  integer default null,
  p_expected_date date default null,
  p_note          text default null,
  p_calves        jsonb default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  c       record;
  v_len   integer;
  v_exp   date;
  v_id    uuid;
  x       jsonb;
begin
  select id, farm_id, owner_id, sex, species, breed_code, birth_year
    into c from cattle where id = p_cattle_id;
  if not found then raise exception 'Мал олдсонгүй.'; end if;
  if not (is_super()
          or (my_role() = 'farm_admin' and c.farm_id = my_farm())
          or (my_role() is not null and c.owner_id = auth.uid())) then
    raise exception 'Зөвхөн эзэмшигч эсвэл админ бүртгэнэ.';
  end if;
  if c.sex <> 'female' then raise exception 'Зөвхөн эм мал.'; end if;
  if p_kind not in ('insemination', 'pregnancy_check', 'calving', 'abortion') then
    raise exception 'Unknown kind %', p_kind;
  end if;
  if p_date is null or p_date > current_date then raise exception 'Огноо буруу (ирээдүй байж болохгүй).'; end if;
  if c.birth_year is not null and extract(year from p_date) < c.birth_year then
    raise exception 'Огноо малын төрсөн оноос өмнө байна.';
  end if;

  v_len := gestation_days(c.breed_code, c.species);    -- null if species unknown
  v_exp := p_expected_date;

  if p_kind = 'insemination' then
    if coalesce(p_method, 'natural') not in ('natural', 'run_with_bull', 'ai', 'embryo') then
      raise exception 'Арга буруу.';
    end if;
    if v_exp is null and v_len is not null then v_exp := p_date + v_len; end if;

  elsif p_kind = 'pregnancy_check' then
    if p_result not in ('pregnant', 'empty', 'unknown') then raise exception 'Үр дүнгээ сонгоно уу.'; end if;
    if p_result = 'pregnant' and v_exp is null then
      if p_foetal_age is not null and v_len is not null then
        v_exp := p_date - p_foetal_age + v_len;
      else
        select expected_date into v_exp from repro_events
        where cattle_id = c.id and kind = 'insemination' and event_date <= p_date
        order by event_date desc, created_at desc limit 1;
      end if;
    end if;
    if p_result <> 'pregnant' then v_exp := null; end if;

  elsif p_kind = 'calving' then
    if p_calves is null or jsonb_typeof(p_calves) <> 'array'
       or jsonb_array_length(p_calves) not between 1 and 4 then
      raise exception 'Төлийн хүйсийг оруулна уу.';
    end if;
    if p_calving_ease is not null and p_calving_ease not between 1 and 5 then
      raise exception 'Төллөлтийн хүндрэл 1–5.';
    end if;
    v_exp := null;

  else  -- abortion
    v_exp := null;
  end if;

  insert into repro_events (farm_id, cattle_id, kind, event_date, method, sire_tag, sire_name,
                            result, check_method, foetal_age_days, calving_ease,
                            expected_date, note, recorded_by)
  values (c.farm_id, c.id, p_kind, p_date,
          case when p_kind = 'insemination' then coalesce(p_method, 'natural') end,
          nullif(trim(p_sire_tag), ''), nullif(trim(p_sire_name), ''),
          case when p_kind = 'pregnancy_check' then p_result end,
          case when p_kind = 'pregnancy_check' then p_check_method end,
          case when p_kind = 'pregnancy_check' then p_foetal_age end,
          case when p_kind = 'calving' then p_calving_ease end,
          v_exp, nullif(trim(p_note), ''), auth.uid())
  returning id into v_id;

  if p_kind = 'calving' then
    for x in select * from jsonb_array_elements(p_calves) loop
      insert into repro_calves (event_id, sex, birth_status, birth_weight_kg)
      values (v_id, x->>'sex', coalesce(x->>'birth_status', 'alive'),
              nullif(x->>'birth_weight_kg', '')::numeric);
    end loop;
  end if;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (c.farm_id, auth.uid(), 'repro_' || p_kind, 'repro_events', v_id,
          jsonb_build_object('cattle_id', c.id, 'date', p_date));
  return v_id;
end $$;

-- Delete a mistaken entry: whoever recorded it (within 7 days) or an admin.
create or replace function delete_repro_event(p_event_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare e record;
begin
  select * into e from repro_events where id = p_event_id;
  if not found then raise exception 'Бүртгэл олдсонгүй.'; end if;
  if not (is_super()
          or (my_role() = 'farm_admin' and e.farm_id = my_farm())
          or (e.recorded_by = auth.uid() and e.created_at > now() - interval '7 days')) then
    raise exception 'Устгах эрхгүй (7 хоногоос хуучин бол админд хандана уу).';
  end if;
  delete from repro_events where id = p_event_id;
  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (e.farm_id, auth.uid(), 'repro_delete', 'repro_events', e.id,
          jsonb_build_object('kind', e.kind, 'date', e.event_date, 'cattle_id', e.cattle_id));
end $$;

-- ============================================================
-- 5. CURRENT STATE PER FEMALE — read by the dashboard
--   bred      inseminated, not yet confirmed
--   pregnant  confirmed by a check
--   open      calved, aborted, or checked empty (сувай)
-- ============================================================
create or replace view repro_status as
select
  c.id as cattle_id, c.farm_id,
  case
    when l.kind = 'insemination'                           then 'bred'
    when l.kind = 'pregnancy_check' and l.result = 'pregnant' then 'pregnant'
    when l.kind = 'pregnancy_check' and l.result = 'unknown'  then 'bred'
    when l.kind is not null                                 then 'open'
  end as state,
  case when l.kind in ('insemination', 'pregnancy_check') then l.expected_date end as expected_date,
  l.event_date as last_event_date,
  (select max(event_date) from repro_events e2 where e2.cattle_id = c.id and e2.kind = 'calving') as last_calving_date,
  (select count(*)        from repro_events e2 where e2.cattle_id = c.id and e2.kind = 'calving') as calvings
from cattle c
left join lateral (
  select kind, result, expected_date, event_date from repro_events e
  where e.cattle_id = c.id
  order by e.event_date desc, e.created_at desc limit 1) l on true
where c.sex = 'female';

alter view repro_status set (security_invoker = on);

-- ============================================================
-- 6. REGISTRATION: species/breed + mother, linking the calf
--
-- Replaces the v25 register_cattle. New parameters all have
-- defaults, so a phone still running the older page keeps working
-- (species just stays "unknown"). Dropped first so the API does not
-- see two versions.
--
-- p_mother_tag: if given and the mother had a recorded calving with
-- an unlinked live calf of this sex, that calf record is linked to
-- this new animal.
-- ============================================================
drop function if exists register_cattle(text, text, integer, text, text, double precision, double precision);

create or replace function register_cattle(
  p_tag_code   text,
  p_sex        text,
  p_birth_year integer,
  p_breed      text default null,
  p_colour     text default null,
  p_lat        double precision default null,
  p_lng        double precision default null,
  p_breed_code text default null,
  p_mother_tag text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  t        record;
  me       record;
  v_id     uuid;
  v_ph     text;
  v_mom    uuid;
  v_species text;             -- stay null when no breed is given (older page)
  v_bcode  text;
  v_bname  text;
  v_other  boolean := false;
begin
  if auth.uid() is null then raise exception 'Нэвтэрнэ үү.'; end if;

  select id, role, farm_id, phone into me
  from profiles where id = auth.uid() and status = 'active';
  if not found then raise exception 'Таны бүртгэл идэвхгүй байна. Админд хандана уу.'; end if;

  select tg.id, tg.status, tg.farm_id, tg.tag_code, f.status as farm_status
    into t
  from tags tg join farms f on f.id = tg.farm_id
  where tg.tag_code = p_tag_code
  for update of tg;
  if not found then raise exception 'Таг олдсонгүй: %', p_tag_code; end if;

  if exists (select 1 from cattle c where c.tag_id = t.id or c.tag_code = t.tag_code) then
    raise exception 'Энэ таг дээр мал аль хэдийн бүртгэгдсэн байна.';
  end if;
  if t.farm_status <> 'active' or t.status not in ('blank', 'written', 'recycled') then
    raise exception 'Энэ таг ашиглах боломжгүй байна. Админд хандана уу.';
  end if;
  if me.role <> 'super_admin' and me.farm_id is distinct from t.farm_id then
    raise exception 'Энэ таг таны фермийнх биш. Админд хандана уу.';
  end if;

  if p_sex not in ('female', 'male') then raise exception 'Хүйсээ сонгоно уу.'; end if;
  if p_birth_year is null or p_birth_year < 1990 or p_birth_year > extract(year from now())::int then
    raise exception 'Төрсөн он буруу байна.';
  end if;

  if p_breed_code is not null then
    select species, code, name_mn, is_other into v_species, v_bcode, v_bname, v_other
    from breeds where code = p_breed_code and active;
    if not found then raise exception 'Үүлдэр буруу.'; end if;
    if v_other and nullif(trim(p_breed), '') is null then
      raise exception '"Бусад" бол үүлдрийн нэрийг бичнэ үү.';
    end if;
  end if;

  if me.phone ~ '^\+?[0-9][0-9 ()-]{5,19}$' then v_ph := me.phone; end if;

  insert into cattle (farm_id, tag_id, tag_code, sex, birth_year,
                      owner_id, registered_by, reg_lat, reg_lng,
                      species, breed_code, breed, colour, mother_tag, contact_phone)
  values (t.farm_id, t.id, t.tag_code, p_sex, p_birth_year,
          me.id, me.id, p_lat, p_lng,
          v_species, v_bcode,
          case when v_bcode is not null and not v_other then v_bname
               else nullif(trim(p_breed), '') end,
          nullif(trim(p_colour), ''),
          nullif(upper(trim(p_mother_tag)), ''), v_ph)
  returning id into v_id;

  update tags set status = 'assigned' where id = t.id;

  -- Link to the mother's calving record, if there is a matching calf.
  if nullif(trim(p_mother_tag), '') is not null then
    select id into v_mom from cattle where tag_code = upper(trim(p_mother_tag));
    if v_mom is not null then
      update repro_calves rc set calf_cattle_id = v_id
      where rc.id = (
        select rc2.id from repro_calves rc2
        join repro_events e on e.id = rc2.event_id
        where e.cattle_id = v_mom and e.kind = 'calving'
          and rc2.sex = p_sex and rc2.birth_status = 'alive'
          and rc2.calf_cattle_id is null
          and e.event_date >= make_date(p_birth_year, 1, 1)
        order by e.event_date desc limit 1);
    end if;
  end if;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (t.farm_id, me.id, 'register_cattle', 'cattle', v_id,
          jsonb_build_object('tag_code', t.tag_code, 'lat', p_lat, 'lng', p_lng,
                             'breed_code', p_breed_code, 'mother_tag', p_mother_tag));
  return v_id;
end $$;

-- ============================================================
-- 7. PERMISSIONS
-- ============================================================
revoke all on function set_cattle_breed(uuid, text, text) from public, anon;
revoke all on function record_repro_event(uuid, text, date, text, text, text, text, text,
                                          integer, integer, date, text, jsonb) from public, anon;
revoke all on function delete_repro_event(uuid) from public, anon;
revoke all on function register_cattle(text, text, integer, text, text, double precision,
                                       double precision, text, text) from public, anon;
grant execute on function set_cattle_breed(uuid, text, text) to authenticated;
grant execute on function record_repro_event(uuid, text, date, text, text, text, text, text,
                                             integer, integer, date, text, jsonb) to authenticated;
grant execute on function delete_repro_event(uuid) to authenticated;
grant execute on function register_cattle(text, text, integer, text, text, double precision,
                                          double precision, text, text) to authenticated;
grant select on breeds, repro_events, repro_calves, repro_status to authenticated;

notify pgrst, 'reload schema';

-- ============================================================
-- CHECK AFTER RUNNING
--   select species, name_mn, gestation_days from breeds order by species, sort_order;
--   select state, count(*) from repro_status group by 1;
-- ============================================================
