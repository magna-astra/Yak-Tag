-- ============================================================
-- YAK-TAG — schema patch v30
-- Expected birth date: a live prediction from all the evidence.
--
-- v28/v29 took one number (the breed's pregnancy length) at the
-- moment of saving. Now the date is PREDICTED every time it is read,
-- from whatever is known, strongest evidence first:
--
--   1. mother's breed           yak 258, Mongolian cattle 283, horse 340 …
--      unknown breed        ->  most common breed among the farm's
--                               females; otherwise the species average
--   2. father                   yak cow + non-yak bull = hybrid (hainag)
--                               pregnancy, carried longer: ~270 days
--                               (FAO: up to ~20 days longer than yak)
--   3. this cow's own history   her past breeding-to-calving intervals
--                               (cows repeat their gestation length)
--   4. the farm's history       observed average for that breed on the
--                               farm, once there are >= 3 calvings
--   5. conception anchor        breeding date, or pregnancy-check date
--                               minus the vet's foetal age
--
-- Blending (shrinkage toward the textbook value):
--   days = (2*base + 0.3*min(farm_n,10)*farm_avg + own_n*own_avg)
--          / (2 + 0.3*min(farm_n,10) + own_n)
-- Only intervals within ±10 % of the base count, so a missed
-- breeding record cannot distort it. The result carries a ± range
-- and a plain-language "basis" so the herder sees why.
--
-- A date typed by hand is kept as it is (expected_is_manual).
-- Safe on the live project and safe to run twice.
-- ============================================================

alter table repro_events add column if not exists expected_is_manual boolean not null default false;

-- ============================================================
-- 1. PREDICTION
-- ============================================================
create or replace function predict_calving(
  p_cattle_id  uuid,
  p_conception date,
  p_sire_tag   text default null
) returns table (expected_date date, gestation integer, spread integer, basis text)
language plpgsql stable security definer set search_path = public as $$
declare
  c         record;
  v_breed   text;
  v_bname   text;
  v_base    numeric;
  v_sire    text;
  v_basis   text[] := '{}';
  own_avg   numeric; own_n int := 0;
  farm_avg  numeric; farm_n int := 0;
  w_farm    numeric := 0;
  v_len     numeric;
begin
  if p_conception is null then return; end if;
  select id, farm_id, species, breed_code into c from cattle where id = p_cattle_id;
  if not found then return; end if;

  -- 1. breed of the mother, or the farm's usual breed
  v_breed := c.breed_code;
  if v_breed is not null then
    select name_mn into v_bname from breeds where code = v_breed;
    v_basis := v_basis || (v_bname || ' ' || gestation_days(v_breed, c.species) || ' хоног');
  else
    select breed_code into v_breed
    from cattle
    where farm_id = c.farm_id and sex = 'female' and breed_code is not null
      and (c.species is null or species = c.species)
    group by breed_code order by count(*) desc limit 1;
    if v_breed is not null then
      select name_mn into v_bname from breeds where code = v_breed;
      v_basis := v_basis || ('үүлдэр сонгоогүй — фермийн ихэнх мал ' || v_bname || ' гэж үзэв');
    end if;
  end if;
  v_base := coalesce((select b.gestation_days from breeds b where b.code = v_breed),
                     case c.species when 'horse' then 340 else 283 end);
  if v_breed is null then
    v_basis := v_basis || (case c.species when 'horse' then 'адууны дундаж 340 хоног'
                                          else 'үхрийн дундаж 283 хоног' end);
  end if;

  -- 2. father: yak cow carrying a hybrid calf
  if v_breed = 'yak' and nullif(trim(p_sire_tag), '') is not null then
    select breed_code into v_sire from cattle where tag_code = upper(trim(p_sire_tag));
    if v_sire is not null and v_sire <> 'yak'
       and (select species from breeds where code = v_sire) = 'cattle' then
      v_base := 270;
      v_basis := v_basis || 'эцэг нь сарлаг биш — эрлийз хээл ~270 хоног'::text;
    end if;
  end if;

  -- 3. this cow's own completed pregnancies
  select avg(g), count(*) into own_avg, own_n from (
    select cv.event_date - i.event_date as g
    from repro_events cv
    join lateral (select event_date from repro_events i
                  where i.cattle_id = cv.cattle_id and i.kind = 'insemination'
                    and i.event_date < cv.event_date
                  order by i.event_date desc limit 1) i on true
    where cv.cattle_id = p_cattle_id and cv.kind = 'calving') x
  where g between v_base * 0.9 and v_base * 1.1;

  -- 4. the farm's completed pregnancies for the same breed (other animals)
  if v_breed is not null then
    select avg(g), count(*) into farm_avg, farm_n from (
      select cv.event_date - i.event_date as g
      from repro_events cv
      join cattle m on m.id = cv.cattle_id
      join lateral (select event_date from repro_events i
                    where i.cattle_id = cv.cattle_id and i.kind = 'insemination'
                      and i.event_date < cv.event_date
                    order by i.event_date desc limit 1) i on true
      where cv.kind = 'calving' and m.farm_id = c.farm_id
        and m.breed_code = v_breed and m.id <> p_cattle_id) x
    where g between v_base * 0.9 and v_base * 1.1;
  end if;
  if farm_n >= 3 then w_farm := 0.3 * least(farm_n, 10); else farm_n := 0; end if;

  v_len := (2 * v_base + w_farm * coalesce(farm_avg, 0) + own_n * coalesce(own_avg, 0))
           / (2 + w_farm + own_n);

  if own_n > 0 then
    v_basis := v_basis || ('энэ малын ' || own_n || ' өмнөх төллөлт (дунджаар ' || round(own_avg) || ' хоног)');
  end if;
  if farm_n > 0 then
    v_basis := v_basis || ('фермийн ' || farm_n || ' төллөлт (дунджаар ' || round(farm_avg) || ' хоног)');
  end if;

  expected_date := p_conception + round(v_len)::int;
  gestation     := round(v_len)::int;
  spread        := case when c.breed_code is null and v_breed is null then 12
                        when c.breed_code is null then 10
                        when own_n >= 2 then 5
                        else 7 end;
  basis         := array_to_string(v_basis, ' · ');
  return next;
end $$;

revoke all on function predict_calving(uuid, date, text) from public, anon;
grant execute on function predict_calving(uuid, date, text) to authenticated;

-- ============================================================
-- 2. CURRENT STATE, WITH THE LIVE PREDICTION
-- Same first columns as v28 (so the dashboard keeps working), plus
-- gestation, spread and basis at the end.
-- ============================================================
create or replace view repro_status as
select
  c.id as cattle_id, c.farm_id,
  case
    when l.kind = 'insemination'                              then 'bred'
    when l.kind = 'pregnancy_check' and l.result = 'pregnant' then 'pregnant'
    when l.kind = 'pregnancy_check' and l.result = 'unknown'  then 'bred'
    when l.kind is not null                                   then 'open'
  end as state,
  case
    when not (l.kind = 'insemination' or (l.kind = 'pregnancy_check' and l.result in ('pregnant', 'unknown')))
      then null
    when l.expected_is_manual then l.expected_date
    else coalesce(p.expected_date, l.expected_date)
  end as expected_date,
  l.event_date as last_event_date,
  (select max(event_date) from repro_events e2 where e2.cattle_id = c.id and e2.kind = 'calving') as last_calving_date,
  (select count(*)        from repro_events e2 where e2.cattle_id = c.id and e2.kind = 'calving') as calvings,
  case when l.expected_is_manual then null else p.gestation end as gestation,
  case when l.expected_is_manual then null else p.spread end   as spread,
  case when l.expected_is_manual then 'гараар оруулсан огноо'
       else p.basis end                                        as basis
from cattle c
left join lateral (
  select kind, result, expected_date, expected_is_manual, event_date, foetal_age_days, sire_tag
  from repro_events e
  where e.cattle_id = c.id
  order by e.event_date desc, e.created_at desc limit 1) l on true
-- conception anchor: the breeding itself, the vet's foetal age, or the
-- latest breeding before the check
left join lateral (
  select
    case when l.kind = 'insemination' then l.event_date
         when l.kind = 'pregnancy_check' and l.foetal_age_days is not null
           then l.event_date - l.foetal_age_days
         else (select i.event_date from repro_events i
               where i.cattle_id = c.id and i.kind = 'insemination' and i.event_date <= l.event_date
               order by i.event_date desc, i.created_at desc limit 1) end as conception,
    case when l.kind = 'insemination' then l.sire_tag
         else (select i.sire_tag from repro_events i
               where i.cattle_id = c.id and i.kind = 'insemination' and i.event_date <= l.event_date
               order by i.event_date desc, i.created_at desc limit 1) end as sire_tag
  ) a on l.kind in ('insemination', 'pregnancy_check')
left join lateral predict_calving(c.id, a.conception, a.sire_tag) p on a.conception is not null
where c.sex = 'female';

alter view repro_status set (security_invoker = on);

-- ============================================================
-- 3. record_repro_event: same as v28, now marking hand-typed dates
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
                            expected_date, expected_is_manual, note, recorded_by)
  values (c.farm_id, c.id, p_kind, p_date,
          case when p_kind = 'insemination' then coalesce(p_method, 'natural') end,
          nullif(trim(p_sire_tag), ''), nullif(trim(p_sire_name), ''),
          case when p_kind = 'pregnancy_check' then p_result end,
          case when p_kind = 'pregnancy_check' then p_check_method end,
          case when p_kind = 'pregnancy_check' then p_foetal_age end,
          case when p_kind = 'calving' then p_calving_ease end,
          v_exp, p_expected_date is not null, nullif(trim(p_note), ''), auth.uid())
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

notify pgrst, 'reload schema';

-- ============================================================
-- CHECK AFTER RUNNING
--   select state, expected_date, spread, basis from repro_status
--   where state in ('bred', 'pregnant') limit 10;
-- ============================================================
