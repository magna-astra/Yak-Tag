-- ============================================================
-- YAK-TAG — schema v55: horses, stage 1 (identity + registration)
--
-- Research: HORSE_RESEARCH.md. Mongolian rules (Order А/405) identify
-- a horse by its brand (тамга) and a coded chip with the national
-- number "MGL" + 10 digits. Horses wear no ear tag, and their chips
-- (134.2 kHz) can't be read by a phone, so a horse is registered
-- WITH or WITHOUT a YAK-TAG tag; the chip / national number, the
-- brand photo and the coat colour identify it.
--
--  1. breeds: the Ministry's official horse list (+ official codes);
--     Жаргалант is not on it — hidden for new animals, kept on the
--     horses already saved with it.
--  2. cattle: chip_no (15 digits), national_id (MGL + 10 digits),
--     castrated (агт), markings (халзан, сартай, булаг …).
--  3. a "brand" (тамга) photo kind.
--  4. set_horse_details(): owner / farm admin / super admin.
--  5. register_horse(): with a tag (as register_cattle) or without.
--  6. cattle_dashboard: species and the horse fields, at the end.
--
-- Run in the Tokyo project (mjijgxfmkgtxmpbmshtl). Safe to run twice.
-- Nothing changes for cattle.
-- ============================================================

do $$
begin
  if to_regclass('public.breeds') is null
     or to_regprocedure('public.register_cattle(text,text,integer,text,text,double precision,double precision,text,text)') is null then
    raise exception 'Wrong database (v28 breeds / registration not here): open the Tokyo project mjijgxfmkgtxmpbmshtl and run again.';
  end if;
end $$;

-- ---------- 1. official horse breeds ----------
alter table public.breeds add column if not exists official_code text;

insert into public.breeds (code, species, name_mn, gestation_days, is_other, sort_order) values
  ('myangad',      'horse', 'Мянгад',            340, false, 60),
  ('undurshil',    'horse', 'Өндөршил',          340, false, 70),
  ('horse_cross',  'horse', 'Эрлийз',            340, false, 80),
  ('thoroughbred', 'horse', 'Англи цэвэр цусны', 340, false, 110),
  ('arabian',      'horse', 'Араб',              340, false, 120),
  ('akhal_teke',   'horse', 'Ахалтекин',         340, false, 130),
  ('budyonny',     'horse', 'Будённый',          340, false, 140),
  ('kabardin',     'horse', 'Кабардин',          340, false, 150),
  ('orlov',        'horse', 'Орлов',             340, false, 160)
on conflict (code) do nothing;

-- the codes the official list gives (the imported breeds' codes are not
-- confirmed one by one, so they stay empty)
update public.breeds b set official_code = v.oc
  from (values ('mongol_horse', '0101'), ('galshar', '0102'), ('tes', '0103'),
               ('darkhad', '0104'), ('myangad', '0105'), ('undurshil', '0106')) v(code, oc)
 where b.code = v.code;

update public.breeds set active = false where code = 'jargalant';

-- ---------- 2. horse identity on the animal ----------
alter table public.cattle
  add column if not exists chip_no     text,
  add column if not exists national_id text,
  add column if not exists castrated   boolean not null default false,
  add column if not exists markings    text[]  not null default '{}';

alter table public.cattle drop constraint if exists cattle_chip_no_check;
alter table public.cattle add constraint cattle_chip_no_check
  check (chip_no is null or chip_no ~ '^[0-9]{15}$');                 -- ISO 11784/11785
alter table public.cattle drop constraint if exists cattle_national_id_check;
alter table public.cattle add constraint cattle_national_id_check
  check (national_id is null or national_id ~ '^MGL[0-9]{10}$');      -- Order А/405, 2.6
alter table public.cattle drop constraint if exists cattle_castrated_check;
alter table public.cattle add constraint cattle_castrated_check
  check (not castrated or sex = 'male');
alter table public.cattle drop constraint if exists cattle_markings_check;
alter table public.cattle add constraint cattle_markings_check
  check (cardinality(markings) <= 8);

-- one horse per chip / national number
create unique index if not exists cattle_chip_no_key     on public.cattle (chip_no)     where chip_no is not null;
create unique index if not exists cattle_national_id_key on public.cattle (national_id) where national_id is not null;

-- ---------- 3. brand (тамга) photo ----------
-- the kind check was made with the table (its name came from Postgres):
-- found by what it checks, then made again with "brand"
do $$
declare r record;
begin
  for r in select conname from pg_constraint
            where conrelid = 'public.cattle_photos'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%kind%'
  loop
    execute format('alter table public.cattle_photos drop constraint %I', r.conname);
  end loop;
end $$;
alter table public.cattle_photos add constraint cattle_photos_kind_check
  check (kind in ('profile', 'muzzle', 'marking', 'transfer', 'health', 'brand'));

-- ---------- 4. horse details ----------
create or replace function public.set_horse_details(
  p_cattle_id   uuid,
  p_chip_no     text,
  p_national_id text,
  p_castrated   boolean,
  p_markings    text[],
  p_colour      text
) returns void language plpgsql security definer set search_path = public as $$
declare
  me     record;
  c      record;
  v_chip text := nullif(regexp_replace(coalesce(p_chip_no, ''), '\s', '', 'g'), '');
  v_nid  text := nullif(upper(regexp_replace(coalesce(p_national_id, ''), '[\s-]', '', 'g')), '');
  v_mark text[];
begin
  if auth.uid() is null then raise exception 'Нэвтэрнэ үү.'; end if;
  select id, role, farm_id into me from profiles where id = auth.uid() and status = 'active';
  if not found then raise exception 'Таны бүртгэл идэвхгүй байна. Админд хандана уу.'; end if;

  select id, farm_id, owner_id, sex, species, tag_code into c from cattle where id = p_cattle_id for update;
  if not found then raise exception 'Мал олдсонгүй.'; end if;
  if not (me.role = 'super_admin'
          or (me.role = 'farm_admin' and me.farm_id = c.farm_id)
          or c.owner_id = me.id) then
    raise exception 'Энэ үйлдлийг хийх эрхгүй.';
  end if;
  if c.species is distinct from 'horse' then raise exception 'Энэ мэдээлэл зөвхөн адуунд.'; end if;

  if v_chip is not null and v_chip !~ '^[0-9]{15}$' then
    raise exception 'Чипийн дугаар 15 оронтой тоо байна.';
  end if;
  if v_nid is not null and v_nid !~ '^MGL[0-9]{10}$' then
    raise exception 'Улсын бүртгэлийн дугаар MGL + 10 оронтой тоо байна (жишээ: MGL0123456789).';
  end if;
  if v_chip is not null and exists (select 1 from cattle where chip_no = v_chip and id <> c.id) then
    raise exception 'Энэ чипийн дугаартай адуу аль хэдийн бүртгэлтэй байна.';
  end if;
  if v_nid is not null and exists (select 1 from cattle where national_id = v_nid and id <> c.id) then
    raise exception 'Энэ улсын дугаартай адуу аль хэдийн бүртгэлтэй байна.';
  end if;
  if coalesce(p_castrated, false) and c.sex <> 'male' then
    raise exception 'Агт гэдэг нь эр адуу.';
  end if;
  select coalesce(array_agg(m order by m), '{}') into v_mark
    from (select distinct left(trim(x), 30) as m from unnest(coalesce(p_markings, '{}')) x
           where nullif(trim(x), '') is not null) s;
  if cardinality(v_mark) > 8 then raise exception 'Тэмдэг 8-аас ихгүй.'; end if;

  update cattle
     set chip_no = v_chip, national_id = v_nid, castrated = coalesce(p_castrated, false),
         markings = v_mark, colour = nullif(left(trim(coalesce(p_colour, '')), 60), '')
   where id = c.id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (c.farm_id, me.id, 'set_horse_details', 'cattle', c.id,
          jsonb_build_object('tag_code', c.tag_code, 'chip_no', v_chip, 'national_id', v_nid,
                             'castrated', coalesce(p_castrated, false), 'markings', v_mark, 'colour', p_colour));
end $$;

-- ---------- 5. registering a horse, with or without a YAK-TAG tag ----------
create or replace function public.register_horse(
  p_sex         text,
  p_birth_year  integer,
  p_breed_code  text,
  p_breed       text             default null,   -- name when "Бусад"
  p_colour      text             default null,   -- зүс
  p_castrated   boolean          default false,
  p_markings    text[]           default '{}',
  p_chip_no     text             default null,
  p_national_id text             default null,
  p_lat         double precision default null,
  p_lng         double precision default null,
  p_mother_tag  text             default null,
  p_tag_code    text             default null    -- null: no YAK-TAG tag
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  me     record;
  b      record;
  v_id   uuid;
  v_farm uuid;
  v_ph   text;
  v_mom  uuid;
begin
  if auth.uid() is null then raise exception 'Нэвтэрнэ үү.'; end if;
  select * into b from breeds where code = p_breed_code and active and species = 'horse';
  if not found then raise exception 'Адууны үүлдрээ сонгоно уу.'; end if;

  if nullif(trim(p_tag_code), '') is not null then
    -- every tag rule stays in one place
    v_id := register_cattle(upper(trim(p_tag_code)), p_sex, p_birth_year, p_breed, p_colour,
                            p_lat, p_lng, p_breed_code, p_mother_tag);
  else
    select id, role, farm_id, phone into me
      from profiles where id = auth.uid() and status = 'active';
    if not found then raise exception 'Таны бүртгэл идэвхгүй байна. Админд хандана уу.'; end if;
    if me.role not in ('herder', 'farm_admin') then
      raise exception 'Адууг малчин эсвэл ферм админ бүртгэнэ.';
    end if;
    if me.farm_id is null then raise exception 'Таны ферм тохируулагдаагүй байна. Админд хандана уу.'; end if;
    v_farm := me.farm_id;
    -- same limit as register_cattle (v51)
    if (select count(*) from cattle where registered_by = me.id and created_at > now() - interval '1 hour') >= 60 then
      raise exception 'Нэг цагт 60-аас олон мал бүртгэх боломжгүй. Түр хүлээгээд дахин оролдоно уу.';
    end if;
    if p_sex not in ('female', 'male') then raise exception 'Хүйсээ сонгоно уу.'; end if;
    if p_birth_year is null or p_birth_year < 1990 or p_birth_year > extract(year from now())::int then
      raise exception 'Төрсөн он буруу байна.';
    end if;
    if b.is_other and nullif(trim(p_breed), '') is null then
      raise exception '"Бусад" бол үүлдрийн нэрийг бичнэ үү.';
    end if;
    if me.phone ~ '^\+?[0-9][0-9 ()-]{5,19}$' then v_ph := me.phone; end if;

    insert into cattle (farm_id, tag_id, tag_code, sex, birth_year, owner_id, registered_by,
                        reg_lat, reg_lng, species, breed_code, breed, mother_tag, contact_phone)
    values (v_farm, null, null, p_sex, p_birth_year, me.id, me.id, p_lat, p_lng,
            'horse', b.code, case when b.is_other then trim(p_breed) else b.name_mn end,
            nullif(upper(trim(p_mother_tag)), ''), v_ph)
    returning id into v_id;

    -- the foal joins its mother's foaling record (as register_cattle)
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
    values (v_farm, me.id, 'register_cattle', 'cattle', v_id,
            jsonb_build_object('tag_code', null, 'species', 'horse', 'lat', p_lat, 'lng', p_lng,
                               'breed_code', p_breed_code, 'mother_tag', p_mother_tag));
  end if;

  -- chip / national number / агт / markings / зүс: checked in one place;
  -- an error here undoes the whole registration
  perform set_horse_details(v_id, p_chip_no, p_national_id, p_castrated, p_markings, p_colour);
  return v_id;
end $$;

revoke all on function public.set_horse_details(uuid, text, text, boolean, text[], text) from public, anon;
revoke all on function public.register_horse(text, integer, text, text, text, boolean, text[], text, text,
                                             double precision, double precision, text, text) from public, anon;
grant execute on function public.set_horse_details(uuid, text, text, boolean, text[], text) to authenticated;
grant execute on function public.register_horse(text, integer, text, text, text, boolean, text[], text, text,
                                                double precision, double precision, text, text) to authenticated;

-- ---------- 6. the animal list: species + horse fields (added at the end) ----------
create or replace view public.cattle_dashboard with (security_invoker = on) as
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
  s.source     as last_scan_source,

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
                         as public_scans_30d,
  (select count(*) from all_scans a where a.cattle_id = c.id) as total_scans,

  -- v55
  c.species, c.breed_code, c.colour, c.chip_no, c.national_id, c.castrated, c.markings

from cattle c
join profiles p on p.id = c.owner_id
join farms f    on f.id = c.farm_id

left join lateral (
  select * from all_scans a
  where a.cattle_id = c.id and a.lat is not null
  order by a.scanned_at desc limit 1) s on true

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

notify pgrst, 'reload schema';
