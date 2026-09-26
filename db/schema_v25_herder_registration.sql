-- ============================================================
-- YAK-TAG — schema patch v25
-- Herders register an animal on a new tag.
--
-- Tags are produced in advance: written to a chip, linked to a farm
-- by the admin (tags.farm_id), but with no animal yet. The first
-- time a signed-in herder opens such a tag, they register the
-- animal. The FARM is never chosen by the herder — it is the tag's
-- farm, set by the admin. The herder becomes the owner; an admin
-- can reassign owner or farm later in the dashboard.
--
-- Safe on the live project and safe to run twice: three new
-- functions, no table or data changes.
-- ============================================================

-- A tag is free when its farm is active, it is not lost/retired,
-- and no animal is on it (deleting an animal marks its tag
-- 'recycled', so that counts as free again).

-- ============================================================
-- 1. PUBLIC: "is this a new, unregistered tag?"
--
-- Lets the tap page show "Шинэ таг — Мал бүртгэх" instead of
-- "not found". Returns 'new' or null — nothing else about the tag.
-- ============================================================
create or replace function public_tag_state(p_tag_code text)
returns text language sql stable security definer set search_path = public as $$
  select case when exists (
    select 1
    from tags t
    join farms f on f.id = t.farm_id
    where t.tag_code = p_tag_code
      and f.status = 'active'
      and t.status in ('blank', 'written', 'recycled')
      and not exists (select 1 from cattle c
                      where c.tag_id = t.id or c.tag_code = t.tag_code)
  ) then 'new' end
$$;

grant execute on function public_tag_state(text) to anon, authenticated;

-- ============================================================
-- 2. SIGNED IN: can I register on this tag, and on which farm?
--
-- reason is one of:
--   ok            — go ahead
--   not_signed_in — no login
--   no_profile    — account disabled or has no profile
--   not_found     — no such tag
--   assigned      — already has an animal
--   unavailable   — tag lost/retired, or farm not active
--   other_farm    — tag belongs to a farm this user is not in
-- ============================================================
create or replace function tag_registration_info(p_tag_code text)
returns table (
  tag_code     text,
  farm_name    text,
  farm_code    text,
  can_register boolean,
  reason       text
) language plpgsql stable security definer set search_path = public as $$
declare
  t    record;
  me   record;
begin
  tag_code := p_tag_code;
  can_register := false;

  if auth.uid() is null then reason := 'not_signed_in'; return next; return; end if;

  select id, role, farm_id into me
  from profiles where id = auth.uid() and status = 'active';
  if not found then reason := 'no_profile'; return next; return; end if;

  select tg.id, tg.status, tg.farm_id, f.name, f.code, f.status as farm_status
    into t
  from tags tg join farms f on f.id = tg.farm_id
  where tg.tag_code = p_tag_code;
  if not found then reason := 'not_found'; return next; return; end if;

  farm_name := t.name;
  farm_code := t.code;

  if exists (select 1 from cattle c where c.tag_id = t.id or c.tag_code = p_tag_code) then
    reason := 'assigned';
  elsif t.farm_status <> 'active' or t.status not in ('blank', 'written', 'recycled') then
    reason := 'unavailable';
  elsif me.role <> 'super_admin' and me.farm_id is distinct from t.farm_id then
    reason := 'other_farm';
  else
    reason := 'ok';
    can_register := true;
  end if;
  return next;
end $$;

revoke all on function tag_registration_info(text) from public, anon;
grant execute on function tag_registration_info(text) to authenticated;

-- ============================================================
-- 3. SIGNED IN: register the animal
--
-- Re-checks everything with the tag row locked, so two phones
-- registering the same tag at once cannot both succeed.
-- ============================================================
create or replace function register_cattle(
  p_tag_code   text,
  p_sex        text,
  p_birth_year integer,
  p_breed      text default null,
  p_colour     text default null,
  p_lat        double precision default null,
  p_lng        double precision default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  t      record;
  me     record;
  v_id   uuid;
  v_ph   text;
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

  if p_sex not in ('female', 'male') then
    raise exception 'Хүйсээ сонгоно уу.';
  end if;
  if p_birth_year is null
     or p_birth_year < 1990
     or p_birth_year > extract(year from now())::int then
    raise exception 'Төрсөн он буруу байна.';
  end if;

  -- The owner's phone becomes the finder's call number, but only if it
  -- passes the v21 phone rule (otherwise that trigger would refuse the
  -- whole registration). The herder can set it on the cow page.
  if me.phone ~ '^\+?[0-9][0-9 ()-]{5,19}$' then v_ph := me.phone; end if;

  insert into cattle (farm_id, tag_id, tag_code, sex, birth_year,
                      owner_id, registered_by, reg_lat, reg_lng,
                      breed, colour, contact_phone)
  values (t.farm_id, t.id, t.tag_code, p_sex, p_birth_year,
          me.id, me.id, p_lat, p_lng,
          nullif(trim(p_breed), ''), nullif(trim(p_colour), ''), v_ph)
  returning id into v_id;

  update tags set status = 'assigned' where id = t.id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (t.farm_id, me.id, 'register_cattle', 'cattle', v_id,
          jsonb_build_object('tag_code', t.tag_code, 'lat', p_lat, 'lng', p_lng));

  return v_id;
end $$;

revoke all on function register_cattle(text, text, integer, text, text,
                                       double precision, double precision) from public, anon;
grant execute on function register_cattle(text, text, integer, text, text,
                                          double precision, double precision) to authenticated;

notify pgrst, 'reload schema';

-- ============================================================
-- CHECK AFTER RUNNING
-- ============================================================
-- A written tag with no animal should say 'new':
--   select public_tag_state('YT-008005');
--
-- Tags ready for herders, per farm:
--   select f.name, count(*) from tags t join farms f on f.id = t.farm_id
--   where t.status in ('blank','written','recycled')
--     and not exists (select 1 from cattle c where c.tag_id = t.id)
--   group by 1;
