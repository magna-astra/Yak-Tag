-- ============================================================
-- YAK-TAG — schema patch v34
-- Permission checks that could not fail closed.
--
-- In SQL, "is_super() or (my_role() = 'farm_admin' and ...) or ..."
-- evaluates to NULL — not false — when the caller has no active role
-- (not signed in, no profile, or a disabled account). Then
--     if not ( ... ) then raise exception ...
-- does NOT raise, because "not NULL" is NULL. Such a caller slipped
-- past the check in the functions below.
--
-- Fix: every such check becomes  if not coalesce( ... , false)  so an
-- unknown role is refused. Nothing else in the functions changes —
-- each is its latest definition with only that expression wrapped
-- (generated from the db/ files). Grants are kept (create or replace).
--
-- Safe on the live project and safe to run twice.
-- ============================================================

-- admin_update_cattle_details — from schema_v33_full_editing.sql
create or replace function admin_update_cattle_details(
  p_cattle_id  uuid,
  p_colour     text,
  p_mother_tag text
) returns void language plpgsql security definer set search_path = public as $$
declare c record;
begin
  select id, farm_id into c from cattle where id = p_cattle_id;
  if not found then raise exception 'Мал олдсонгүй.'; end if;
  if not coalesce(is_super() or (my_role() = 'farm_admin' and c.farm_id = my_farm()), false) then
    raise exception 'Зөвхөн админ засна.';
  end if;
  update cattle
     set colour = nullif(trim(p_colour), ''),
         mother_tag = nullif(upper(trim(p_mother_tag)), '')
   where id = p_cattle_id;
end $$;

-- admin_update_vaccination — from schema_v32_vaccination_rules.sql
create or replace function admin_update_vaccination(
  p_cattle_id uuid,
  p_vaccine   text,
  p_given_on  date,
  p_next_due  date
) returns void language plpgsql security definer set search_path = public as $$
declare
  c    record;
  v_id uuid;
begin
  select id, farm_id into c from cattle where id = p_cattle_id;
  if not found then raise exception 'Мал олдсонгүй.'; end if;
  if not coalesce(is_super() or (my_role() = 'farm_admin' and c.farm_id = my_farm()), false) then
    raise exception 'Зөвхөн админ засна.';
  end if;
  if nullif(trim(p_vaccine), '') is null or p_given_on is null then
    raise exception 'Вакцины нэр, огноог оруулна уу.';
  end if;
  if p_given_on > current_date then raise exception 'Хийсэн огноо ирээдүй байж болохгүй.'; end if;
  if p_next_due is not null and p_next_due <= p_given_on then
    raise exception 'Дараагийн огноо хийсэн огнооноос хойш байх ёстой.';
  end if;

  select id into v_id from health_events
  where cattle_id = p_cattle_id and kind = 'vaccination'
  order by coalesce(given_on, occurred_at::date) desc, occurred_at desc limit 1;
  if v_id is null then raise exception 'Засах вакцин алга — эхлээд бүртгэнэ үү.'; end if;

  update health_events
     set vaccine_name = trim(p_vaccine), title = trim(p_vaccine),
         given_on = p_given_on, occurred_at = p_given_on::timestamptz, due_next = p_next_due
   where id = v_id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (c.farm_id, auth.uid(), 'vaccination_edit', 'health_events', v_id,
          jsonb_build_object('cattle_id', p_cattle_id, 'given_on', p_given_on, 'next_due', p_next_due));
end $$;

-- delete_repro_event — from schema_v28_breeds_calving.sql
create or replace function delete_repro_event(p_event_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare e record;
begin
  select * into e from repro_events where id = p_event_id;
  if not found then raise exception 'Бүртгэл олдсонгүй.'; end if;
  if not coalesce(is_super()
          or (my_role() = 'farm_admin' and e.farm_id = my_farm())
          or (e.recorded_by = auth.uid() and e.created_at > now() - interval '7 days'), false) then
    raise exception 'Устгах эрхгүй (7 хоногоос хуучин бол админд хандана уу).';
  end if;
  delete from repro_events where id = p_event_id;
  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (e.farm_id, auth.uid(), 'repro_delete', 'repro_events', e.id,
          jsonb_build_object('kind', e.kind, 'date', e.event_date, 'cattle_id', e.cattle_id));
end $$;

-- log_feeding — from schema_v33_full_editing.sql
create or replace function log_feeding(
  p_cattle_id uuid,
  p_title text default 'Тэжээл',
  p_detail text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  c    record;
  v_id uuid;
begin
  select id, farm_id, owner_id into c from cattle where id = p_cattle_id;
  if not found then raise exception 'Мал олдсонгүй.'; end if;
  if not coalesce(is_super()
          or (my_role() = 'farm_admin' and c.farm_id = my_farm())
          or (my_role() is not null and c.owner_id = auth.uid()), false) then
    raise exception 'Зөвхөн эзэмшигч эсвэл админ.';
  end if;

  insert into health_events (farm_id, cattle_id, kind, title, detail, recorded_by)
  values (c.farm_id, p_cattle_id, 'feeding', coalesce(nullif(trim(p_title), ''), 'Тэжээл'), p_detail, auth.uid())
  returning id into v_id;
  return v_id;
end $$;

-- log_vaccination — from schema_v32_vaccination_rules.sql
create or replace function log_vaccination(
  p_cattle_id  uuid,
  p_vaccine    text,
  p_given_on   date,
  p_next_due   date,
  p_note       text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  c     record;
  last  record;
  v_id  uuid;
  v_admin boolean;
begin
  select id, farm_id, owner_id into c from cattle where id = p_cattle_id;
  if not found then raise exception 'Мал олдсонгүй.'; end if;

  v_admin := coalesce(is_super() or (my_role() = 'farm_admin' and c.farm_id = my_farm()), false);
  if not coalesce(v_admin or (my_role() is not null and c.owner_id = auth.uid()), false) then
    raise exception 'Зөвхөн эзэмшигч эсвэл админ вакцин бүртгэнэ.';
  end if;
  if nullif(trim(p_vaccine), '') is null or p_given_on is null then
    raise exception 'Вакцины нэр, огноог оруулна уу.';
  end if;
  if p_given_on > current_date then raise exception 'Хийсэн огноо ирээдүй байж болохгүй.'; end if;
  if p_next_due is not null and p_next_due <= p_given_on then
    raise exception 'Дараагийн огноо хийсэн огнооноос хойш байх ёстой.';
  end if;

  if not v_admin then
    select given_on, due_next into last from health_events
    where cattle_id = p_cattle_id and kind = 'vaccination'
    order by coalesce(given_on, occurred_at::date) desc, occurred_at desc limit 1;
    if found and (
         (last.due_next is not null and last.due_next > current_date + 30)
      or (last.due_next is null and last.given_on > current_date - 30)) then
      raise exception 'Энэ малд вакцин бүртгэгдсэн байна. Засах бол админд хандана уу.';
    end if;
  end if;

  insert into health_events
    (farm_id, cattle_id, kind, title, detail, vaccine_name,
     given_on, occurred_at, due_next, recorded_by)
  values
    (c.farm_id, p_cattle_id, 'vaccination', trim(p_vaccine), p_note, trim(p_vaccine),
     p_given_on, p_given_on::timestamptz, p_next_due, auth.uid())
  returning id into v_id;

  return v_id;
end $$;

-- record_repro_event — from schema_v31_offline_repro.sql
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
  if not coalesce(is_super()
          or (my_role() = 'farm_admin' and c.farm_id = my_farm())
          or (my_role() is not null and c.owner_id = auth.uid()), false) then
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

-- record_tag_write — from schema_v5_tag_lifecycle.sql
create or replace function record_tag_write(
  p_tag_code text,
  p_nfc_uid text,
  p_protected boolean default true
) returns void language plpgsql security definer set search_path = public as $$
declare
  t record;
begin
  select * into t from tags where tag_code = p_tag_code;
  if not found then raise exception 'Tag % not found', p_tag_code; end if;

  if not coalesce(is_super() or (my_role() = 'farm_admin' and t.farm_id = my_farm()), false) then
    raise exception 'Only a farm admin can write tags';
  end if;

  update tags
     set nfc_uid = p_nfc_uid,
         status = 'written',
         written_at = now(),
         protected = p_protected,
         write_count = write_count + 1
   where id = t.id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (t.farm_id, auth.uid(), 'tag_write', 'tags', t.id,
          jsonb_build_object('tag_code', p_tag_code, 'nfc_uid', p_nfc_uid));
end $$;

-- recycle_tag — from schema_v5_tag_lifecycle.sql
create or replace function recycle_tag(p_tag_code text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  t record;
  c record;
begin
  select * into t from tags where tag_code = p_tag_code;
  if not found then raise exception 'Tag % not found', p_tag_code; end if;

  if not coalesce(is_super() or (my_role() = 'farm_admin' and t.farm_id = my_farm()), false) then
    raise exception 'Only a farm admin can recycle a tag';
  end if;

  if t.retired_at is not null then
    raise exception 'Tag % is retired and cannot be recycled', p_tag_code;
  end if;

  select * into c from cattle where tag_id = t.id;
  if found and c.status = 'active' then
    raise exception
      'Cannot recycle: % is still on an active animal (%). Close that animal out first.',
      p_tag_code, c.id;
  end if;

  -- detach from the old animal, keeping the animal's history intact
  update cattle set tag_id = null where tag_id = t.id;

  update tags
     set status = 'recycled',
         nfc_uid = null,              -- new UID gets recorded on rewrite
         last_wiped_at = now(),
         write_count = write_count + 1
   where id = t.id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (t.farm_id, auth.uid(), 'tag_recycle', 'tags', t.id,
          jsonb_build_object('tag_code', p_tag_code, 'note', p_note,
                             'previous_cattle_id', c.id));
end $$;

-- report_found — from schema_v7_public_page.sql
create or replace function report_found(p_cattle_id uuid)
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

  update cattle
     set reported_lost_at = null, lost_note = null, status = 'active'
   where id = p_cattle_id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (c.farm_id, auth.uid(), 'report_found', 'cattle', p_cattle_id, '{}'::jsonb);
end $$;

-- report_lost — from schema_v7_public_page.sql
create or replace function report_lost(p_cattle_id uuid, p_note text)
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

  update cattle
     set reported_lost_at = now(), lost_note = p_note, status = 'lost'
   where id = p_cattle_id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (c.farm_id, auth.uid(), 'report_lost', 'cattle', p_cattle_id,
          jsonb_build_object('note', p_note));
end $$;

-- retire_tag — from schema_v5_tag_lifecycle.sql
create or replace function retire_tag(p_tag_code text, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  t record;
begin
  select * into t from tags where tag_code = p_tag_code;
  if not found then raise exception 'Tag % not found', p_tag_code; end if;

  if not coalesce(is_super() or (my_role() = 'farm_admin' and t.farm_id = my_farm()), false) then
    raise exception 'Only a farm admin can retire a tag';
  end if;

  -- detach from any animal first, so the cow is not left pointing at a dead tag
  update cattle set tag_id = null where tag_id = t.id;

  update tags
     set status = 'retired', retired_at = now(), retire_reason = p_reason
   where id = t.id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (t.farm_id, auth.uid(), 'tag_retire', 'tags', t.id,
          jsonb_build_object('tag_code', p_tag_code, 'reason', p_reason));
end $$;

-- set_cattle_breed — from schema_v29_expected_date_fix.sql
create or replace function set_cattle_breed(
  p_cattle_id  uuid,
  p_breed_code text,
  p_breed_text text default null
) returns void language plpgsql security definer set search_path = public as $$
declare
  c  record;
  b  record;
begin
  select id, farm_id, owner_id into c from cattle where id = p_cattle_id;
  if not found then raise exception 'Мал олдсонгүй.'; end if;
  if not coalesce(is_super()
          or (my_role() = 'farm_admin' and c.farm_id = my_farm())
          or (my_role() is not null and c.owner_id = auth.uid()), false) then
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

  perform fill_expected_dates(p_cattle_id);
end $$;

-- set_contact_phone — from schema_v11_public_minimal.sql
create or replace function set_contact_phone(
  p_cattle_id uuid,
  p_phone     text,
  p_lock      boolean default false
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

-- set_public_photo — from schema_v14_photo_fix.sql
create or replace function set_public_photo(
  p_cattle_id uuid,
  p_path      text
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

  update cattle set public_photo_path = p_path where id = p_cattle_id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (c.farm_id, auth.uid(), 'set_public_photo', 'cattle', p_cattle_id,
          jsonb_build_object('path', p_path));
end $$;

-- unlock_contact_phone — from schema_v11_public_minimal.sql
create or replace function unlock_contact_phone(p_cattle_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare c record;
begin
  select * into c from cattle where id = p_cattle_id;
  if not found then raise exception 'Animal not found'; end if;

  if not coalesce(is_super() or (my_role() = 'farm_admin' and c.farm_id = my_farm()), false) then
    raise exception 'Only a farm admin can unlock a number';
  end if;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (c.farm_id, auth.uid(), 'unlock_contact_phone', 'cattle', p_cattle_id,
          jsonb_build_object('reason', p_reason));

  update cattle set contact_locked_at = null, contact_locked_by = null
   where id = p_cattle_id;
end $$;

notify pgrst, 'reload schema';
