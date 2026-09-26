-- ============================================================
-- YAK-TAG — schema patch v31
-- Offline entry of pregnancy / calving records.
--
-- The phone keeps entries made without signal and sends them later
-- (offline.js). A dropped connection can make it send the same entry
-- twice, so each entry carries a client_uuid made on the phone, and
-- the server answers a repeat with the entry it already has.
--
-- Milk needs no change: milk_yield is one row per cow per day
-- (upsert on cattle_id, yield_date), so a repeat is harmless.
--
-- record_repro_event is the v30 function plus p_client_uuid (last,
-- with a default — pages that do not send it keep working). It is
-- dropped first so the API does not see two versions.
-- Safe on the live project and safe to run twice.
-- ============================================================

alter table repro_events add column if not exists client_uuid uuid;
create unique index if not exists repro_events_client_uuid_idx
  on repro_events (client_uuid) where client_uuid is not null;

drop function if exists record_repro_event(uuid, text, date, text, text, text, text, text,
                                           integer, integer, date, text, jsonb);

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
  p_calves        jsonb default null,
  p_client_uuid   uuid default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  c       record;
  v_len   integer;
  v_exp   date;
  v_id    uuid;
  x       jsonb;
begin
  -- A phone resending an entry it already delivered (offline queue).
  if p_client_uuid is not null then
    select id into v_id from repro_events where client_uuid = p_client_uuid;
    if found then return v_id; end if;
  end if;

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
                            expected_date, expected_is_manual, note, recorded_by, client_uuid)
  values (c.farm_id, c.id, p_kind, p_date,
          case when p_kind = 'insemination' then coalesce(p_method, 'natural') end,
          nullif(trim(p_sire_tag), ''), nullif(trim(p_sire_name), ''),
          case when p_kind = 'pregnancy_check' then p_result end,
          case when p_kind = 'pregnancy_check' then p_check_method end,
          case when p_kind = 'pregnancy_check' then p_foetal_age end,
          case when p_kind = 'calving' then p_calving_ease end,
          v_exp, p_expected_date is not null, nullif(trim(p_note), ''), auth.uid(), p_client_uuid)
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

revoke all on function record_repro_event(uuid, text, date, text, text, text, text, text,
                                          integer, integer, date, text, jsonb, uuid) from public, anon;
grant execute on function record_repro_event(uuid, text, date, text, text, text, text, text,
                                             integer, integer, date, text, jsonb, uuid) to authenticated;

notify pgrst, 'reload schema';

-- ============================================================
-- CHECK AFTER RUNNING — exactly one version, 14 arguments:
--   select pg_get_function_identity_arguments(oid)
--   from pg_proc where proname = 'record_repro_event';
-- ============================================================
