-- ============================================================
-- YAK-TAG — schema patch v32
-- Vaccination: herder records once, only an admin changes it.
--
-- 1. log_vaccination had NO permission check: any signed-in user
--    could add a vaccination to any animal of any farm. Now only the
--    owner, the farm's admin or the super admin may.
-- 2. A herder records a vaccination ONCE. While the animal's latest
--    vaccination is still current (next dose more than 30 days
--    away, or given within the last 30 days when no next date), the
--    herder cannot add another — that would be a second entry for
--    the same dose. Admins are not limited.
-- 3. admin_update_vaccination: the farm admin or super admin corrects
--    the latest vaccination (name, date given, next due date).
--
-- Same signature for log_vaccination, so the pages keep working.
-- Safe on the live project and safe to run twice.
-- ============================================================

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

  v_admin := is_super() or (my_role() = 'farm_admin' and c.farm_id = my_farm());
  if not (v_admin or (my_role() is not null and c.owner_id = auth.uid())) then
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
  if not (is_super() or (my_role() = 'farm_admin' and c.farm_id = my_farm())) then
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

revoke all on function log_vaccination(uuid, text, date, date, text) from public, anon;
revoke all on function admin_update_vaccination(uuid, text, date, date) from public, anon;
grant execute on function log_vaccination(uuid, text, date, date, text) to authenticated;
grant execute on function admin_update_vaccination(uuid, text, date, date) to authenticated;

notify pgrst, 'reload schema';
