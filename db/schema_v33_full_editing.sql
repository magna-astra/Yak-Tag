-- ============================================================
-- YAK-TAG — schema patch v33
-- Everything editable from the screens, and one missing check.
--
-- 1. log_feeding had NO permission check: anyone — even without
--    logging in — could add feeding records to any animal whose id
--    they knew. Now: owner, the farm's admin, or super admin.
-- 2. admin_update_cattle_details: colour and mother's tag (sex,
--    breed, year, weight, owner, farm, status were already editable).
-- 3. admin_update_farm: correct a farm's code, name, aimag, soum and
--    location after it was created.
-- 4. admin_set_tag_uid: record (or clear) the chip UID of a tag from
--    the Tags tab, instead of SQL. A blank tag becomes 'written'.
--
-- Same signature for log_feeding. Safe to run twice.
-- ============================================================

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
  if not (is_super()
          or (my_role() = 'farm_admin' and c.farm_id = my_farm())
          or (my_role() is not null and c.owner_id = auth.uid())) then
    raise exception 'Зөвхөн эзэмшигч эсвэл админ.';
  end if;

  insert into health_events (farm_id, cattle_id, kind, title, detail, recorded_by)
  values (c.farm_id, p_cattle_id, 'feeding', coalesce(nullif(trim(p_title), ''), 'Тэжээл'), p_detail, auth.uid())
  returning id into v_id;
  return v_id;
end $$;

create or replace function admin_update_cattle_details(
  p_cattle_id  uuid,
  p_colour     text,
  p_mother_tag text
) returns void language plpgsql security definer set search_path = public as $$
declare c record;
begin
  select id, farm_id into c from cattle where id = p_cattle_id;
  if not found then raise exception 'Мал олдсонгүй.'; end if;
  if not (is_super() or (my_role() = 'farm_admin' and c.farm_id = my_farm())) then
    raise exception 'Зөвхөн админ засна.';
  end if;
  update cattle
     set colour = nullif(trim(p_colour), ''),
         mother_tag = nullif(upper(trim(p_mother_tag)), '')
   where id = p_cattle_id;
end $$;

create or replace function admin_update_farm(
  p_farm_id uuid,
  p_code    text,
  p_name    text,
  p_aimag   text,
  p_soum    text,
  p_lat     double precision,
  p_lng     double precision
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_super() then raise exception 'Зөвхөн ерөнхий админ.'; end if;
  if nullif(trim(p_code), '') is null or nullif(trim(p_name), '') is null then
    raise exception 'Код болон нэрийг оруулна уу.';
  end if;
  if p_lat is not null and (p_lat < -90 or p_lat > 90) then raise exception 'Өргөрөг буруу.'; end if;
  if p_lng is not null and (p_lng < -180 or p_lng > 180) then raise exception 'Уртраг буруу.'; end if;
  update farms
     set code = trim(p_code), name = trim(p_name),
         aimag = nullif(trim(p_aimag), ''), soum = nullif(trim(p_soum), ''),
         center_lat = p_lat, center_lng = p_lng
   where id = p_farm_id;
  if not found then raise exception 'Ферм олдсонгүй.'; end if;
end $$;

create or replace function admin_set_tag_uid(p_tag_code text, p_uid text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid text := nullif(upper(regexp_replace(coalesce(p_uid, ''), '[^0-9A-Fa-f]', '', 'g')), '');
  t     record;
begin
  if not is_super() then raise exception 'Зөвхөн ерөнхий админ.'; end if;
  if v_uid is not null and length(v_uid) not in (8, 14, 20) then
    raise exception 'Чип UID буруу (7 байт = 14 тэмдэгт, жишээ: 04B7A594C82A81).';
  end if;
  select * into t from tags where tag_code = p_tag_code;
  if not found then raise exception 'Таг олдсонгүй: %', p_tag_code; end if;
  if v_uid is not null and exists (select 1 from tags where nfc_uid = v_uid and id <> t.id) then
    raise exception 'Энэ UID өөр таг дээр бүртгэлтэй байна.';
  end if;

  update tags
     set nfc_uid = v_uid,
         written_at = case when v_uid is not null then coalesce(written_at, now()) else written_at end,
         status = case when v_uid is not null and status = 'blank' then 'written' else status end
   where id = t.id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (t.farm_id, auth.uid(), 'tag_uid', 'tags', t.id,
          jsonb_build_object('tag_code', p_tag_code, 'nfc_uid', v_uid));
end $$;

revoke all on function log_feeding(uuid, text, text) from public, anon;
revoke all on function admin_update_cattle_details(uuid, text, text) from public, anon;
revoke all on function admin_update_farm(uuid, text, text, text, text, double precision, double precision) from public, anon;
revoke all on function admin_set_tag_uid(text, text) from public, anon;
grant execute on function log_feeding(uuid, text, text) to authenticated;
grant execute on function admin_update_cattle_details(uuid, text, text) to authenticated;
grant execute on function admin_update_farm(uuid, text, text, text, text, double precision, double precision) to authenticated;
grant execute on function admin_set_tag_uid(text, text) to authenticated;

notify pgrst, 'reload schema';
