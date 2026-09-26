-- ============================================================
-- YAK-TAG — schema patch v35
-- Correct mistakes: delete a feeding entry, edit a pregnancy /
-- calving entry.
--
-- Who may change an entry (same rule as delete_repro_event):
--   whoever recorded it, within 7 days, or
--   the farm's admin / the super admin, any time.
-- Permission checks are null-safe (see v34).
--
-- Safe on the live project and safe to run twice.
-- ============================================================

-- ============================================================
-- 1. DELETE A FEEDING ENTRY
-- ============================================================
create or replace function delete_feeding(p_event_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare e record;
begin
  select * into e from health_events where id = p_event_id and kind = 'feeding';
  if not found then raise exception 'Тэжээлийн бүртгэл олдсонгүй.'; end if;
  if not coalesce(is_super()
          or (my_role() = 'farm_admin' and e.farm_id = my_farm())
          or (my_role() is not null and e.recorded_by = auth.uid()
              and e.occurred_at > now() - interval '7 days'), false) then
    raise exception 'Устгах эрхгүй (7 хоногоос хуучин бол админд хандана уу).';
  end if;
  delete from health_events where id = p_event_id;
  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (e.farm_id, auth.uid(), 'feeding_delete', 'health_events', e.id,
          jsonb_build_object('cattle_id', e.cattle_id, 'occurred_at', e.occurred_at));
end $$;

-- ============================================================
-- 2. EDIT A PREGNANCY / CALVING ENTRY
--
-- Same fields as record_repro_event; the kind itself does not change
-- (delete and re-enter for that). For a calving, p_calves lists every
-- calf: [{"id":"…","sex":…,"birth_status":…,"birth_weight_kg":…}].
-- A calf with an id is updated, one without is added, and a calf left
-- out is removed — unless it is already linked to its own tag.
-- Expected date: typed by hand -> kept (manual); left empty -> the
-- live prediction in repro_status is used (v30).
-- ============================================================
create or replace function update_repro_event(
  p_event_id      uuid,
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
) returns void language plpgsql security definer set search_path = public as $$
declare
  e    record;
  c    record;
  x     jsonb;
  keep  uuid[] := '{}';
  v_new uuid;
begin
  select * into e from repro_events where id = p_event_id;
  if not found then raise exception 'Бүртгэл олдсонгүй.'; end if;
  if not coalesce(is_super()
          or (my_role() = 'farm_admin' and e.farm_id = my_farm())
          or (my_role() is not null and e.recorded_by = auth.uid()
              and e.created_at > now() - interval '7 days'), false) then
    raise exception 'Засах эрхгүй (7 хоногоос хуучин бол админд хандана уу).';
  end if;

  select birth_year into c from cattle where id = e.cattle_id;
  if p_date is null or p_date > current_date then raise exception 'Огноо буруу (ирээдүй байж болохгүй).'; end if;
  if c.birth_year is not null and extract(year from p_date) < c.birth_year then
    raise exception 'Огноо малын төрсөн оноос өмнө байна.';
  end if;
  if p_expected_date is not null and p_expected_date <= p_date then
    raise exception 'Төллөх огноо үйл явдлын огнооноос хойш байх ёстой.';
  end if;

  if e.kind = 'insemination' and coalesce(p_method, 'natural') not in ('natural', 'run_with_bull', 'ai', 'embryo') then
    raise exception 'Арга буруу.';
  end if;
  if e.kind = 'pregnancy_check' and p_result not in ('pregnant', 'empty', 'unknown') then
    raise exception 'Үр дүнгээ сонгоно уу.';
  end if;
  if e.kind = 'calving' then
    if p_calving_ease is not null and p_calving_ease not between 1 and 5 then
      raise exception 'Төллөлтийн хүндрэл 1–5.';
    end if;
    if p_calves is null or jsonb_typeof(p_calves) <> 'array'
       or jsonb_array_length(p_calves) not between 1 and 4 then
      raise exception 'Төлийн хүйсийг оруулна уу.';
    end if;
  end if;

  update repro_events set
    event_date      = p_date,
    method          = case when kind = 'insemination' then coalesce(p_method, 'natural') end,
    sire_tag        = case when kind = 'insemination' then nullif(upper(trim(p_sire_tag)), '') end,
    sire_name       = case when kind = 'insemination' then nullif(trim(p_sire_name), '') end,
    result          = case when kind = 'pregnancy_check' then p_result end,
    check_method    = case when kind = 'pregnancy_check' then p_check_method end,
    foetal_age_days = case when kind = 'pregnancy_check' then p_foetal_age end,
    calving_ease    = case when kind = 'calving' then p_calving_ease end,
    expected_date   = case when kind = 'insemination'
                             or (kind = 'pregnancy_check' and p_result = 'pregnant')
                           then p_expected_date end,
    expected_is_manual = p_expected_date is not null
                         and (kind = 'insemination' or (kind = 'pregnancy_check' and p_result = 'pregnant')),
    note            = nullif(trim(p_note), '')
  where id = p_event_id;

  if e.kind = 'calving' then
    for x in select * from jsonb_array_elements(p_calves) loop
      if x->>'sex' not in ('female', 'male') then raise exception 'Төлийн хүйсийг сонгоно уу.'; end if;
      if nullif(x->>'id', '') is not null
         and exists (select 1 from repro_calves where id = (x->>'id')::uuid and event_id = p_event_id) then
        update repro_calves
           set sex = x->>'sex', birth_status = coalesce(x->>'birth_status', 'alive'),
               birth_weight_kg = nullif(x->>'birth_weight_kg', '')::numeric
         where id = (x->>'id')::uuid;
        keep := keep || (x->>'id')::uuid;
      else
        insert into repro_calves (event_id, sex, birth_status, birth_weight_kg)
        values (p_event_id, x->>'sex', coalesce(x->>'birth_status', 'alive'),
                nullif(x->>'birth_weight_kg', '')::numeric)
        returning id into v_new;
        keep := keep || v_new;
      end if;
    end loop;
    -- calves left out of the list are removed, unless already tagged
    if exists (select 1 from repro_calves where event_id = p_event_id
               and id <> all(keep) and calf_cattle_id is not null) then
      raise exception 'Тагтай болсон төлийг хасах боломжгүй.';
    end if;
    delete from repro_calves where event_id = p_event_id and id <> all(keep);
  end if;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (e.farm_id, auth.uid(), 'repro_edit', 'repro_events', e.id,
          jsonb_build_object('kind', e.kind, 'old_date', e.event_date, 'new_date', p_date));
end $$;

revoke all on function delete_feeding(uuid) from public, anon;
revoke all on function update_repro_event(uuid, date, text, text, text, text, text, integer, integer, date, text, jsonb) from public, anon;
grant execute on function delete_feeding(uuid) to authenticated;
grant execute on function update_repro_event(uuid, date, text, text, text, text, text, integer, integer, date, text, jsonb) to authenticated;

notify pgrst, 'reload schema';
