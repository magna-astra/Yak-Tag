-- ============================================================
-- YAK-TAG — schema patch v50
-- "Фермгүй (агуулах)": a stock for unused tags.
--
-- A tag no longer has to belong to a farm. Unused tags can sit in the
-- stock (farm = none), safe from any farm being paused or deleted:
--   · "+ Таг үүсгэх" can create tags straight into the stock;
--   · "Ферм солих" moves unused tags to a farm or back to the stock;
--   · a stock tag works like any new tag — the herder who registers an
--     animal on it gets it in his farm;
--   · replacing a lost tag may use a stock tag;
--   · deleting a farm no longer deletes its tag numbers: they go to the
--     stock (a tag whose animal was deleted can carry a new animal).
-- Needs v49. Safe on the live project and safe to run twice. All or
-- nothing: if any line fails, nothing is changed.
-- ============================================================

begin;

do $$
begin
  if to_regprocedure('public.admin_pause_tags(text[],boolean,text)') is null then
    raise exception 'Run db/schema_v49_admin_role_pause.sql first (or wrong database: open project oxfbxqclqfglpzgzizhq).';
  end if;
end $$;

alter table public.tags        alter column farm_id drop not null;
alter table public.tag_batches alter column farm_id drop not null;


-- ---------- registration page: a stock tag is a normal new tag ----------

CREATE OR REPLACE FUNCTION public.tag_registration_info(p_tag_code text)
 RETURNS TABLE(tag_code text, farm_name text, farm_code text, can_register boolean, reason text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  select tg.id, tg.status, tg.farm_id, tg.paused_at, f.name, f.code, f.status as farm_status
    into t
  from tags tg left join farms f on f.id = tg.farm_id      -- v50: stock tags have no farm
  where tg.tag_code = p_tag_code;
  if not found then reason := 'not_found'; return next; return; end if;

  -- the farm the animal will belong to
  if me.role in ('herder', 'farm_admin') and me.farm_id is not null then
    select f.name, f.code into farm_name, farm_code from farms f where f.id = me.farm_id;
  else
    farm_name := t.name;
    farm_code := t.code;
  end if;

  if exists (select 1 from cattle c where c.tag_id = t.id or c.tag_code = p_tag_code) then
    reason := 'assigned';
  elsif t.paused_at is not null or coalesce(t.farm_status, 'active') <> 'active' then
    reason := 'paused';
  elsif t.status not in ('blank', 'written', 'recycled') then
    reason := 'unavailable';
  elsif me.role not in ('herder', 'farm_admin', 'super_admin')
        or (me.role <> 'super_admin' and me.farm_id is null)
        or (me.role = 'super_admin' and t.farm_id is null) then
    reason := 'no_farm';
  else
    reason := 'ok';
    can_register := true;
  end if;
  return next;
end $function$;

-- ---------- registration: stock tag joins the herder's farm ----------

CREATE OR REPLACE FUNCTION public.register_cattle(p_tag_code text, p_sex text, p_birth_year integer, p_breed text DEFAULT NULL::text, p_colour text DEFAULT NULL::text, p_lat double precision DEFAULT NULL::double precision, p_lng double precision DEFAULT NULL::double precision, p_breed_code text DEFAULT NULL::text, p_mother_tag text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_farm   uuid;
begin
  if auth.uid() is null then raise exception 'Нэвтэрнэ үү.'; end if;

  select id, role, farm_id, phone into me
  from profiles where id = auth.uid() and status = 'active';
  if not found then raise exception 'Таны бүртгэл идэвхгүй байна. Админд хандана уу.'; end if;

  select tg.id, tg.status, tg.farm_id, tg.tag_code, tg.paused_at, f.status as farm_status
    into t
  from tags tg left join farms f on f.id = tg.farm_id      -- v50: stock tags have no farm
  where tg.tag_code = p_tag_code
  for update of tg;
  if not found then raise exception 'Таг олдсонгүй: %', p_tag_code; end if;

  if exists (select 1 from cattle c where c.tag_id = t.id or c.tag_code = t.tag_code) then
    raise exception 'Энэ таг дээр мал аль хэдийн бүртгэгдсэн байна.';
  end if;
  if t.paused_at is not null or coalesce(t.farm_status, 'active') <> 'active' then
    raise exception 'Энэ таг түр зогсоогдсон. Админд хандана уу.';
  end if;
  if t.status not in ('blank', 'written', 'recycled') then
    raise exception 'Энэ таг ашиглах боломжгүй байна. Админд хандана уу.';
  end if;
  -- v49: any new tag may be registered; it moves to the herder's farm
  if me.role in ('herder', 'farm_admin') then
    if me.farm_id is null then raise exception 'Таны ферм тохируулагдаагүй байна. Админд хандана уу.'; end if;
    v_farm := me.farm_id;
  elsif me.role = 'super_admin' then
    v_farm := t.farm_id;
    if v_farm is null then
      raise exception 'Агуулахын (фермгүй) таг: малчин өөрөө нэвтэрч бүртгэнэ, эсвэл эхлээд фермд оноо.';
    end if;
  else
    raise exception 'Мал малчин эсвэл ферм админ бүртгэнэ.';
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
  values (v_farm, t.id, t.tag_code, p_sex, p_birth_year,
          me.id, me.id, p_lat, p_lng,
          v_species, v_bcode,
          case when v_bcode is not null and not v_other then v_bname
               else nullif(trim(p_breed), '') end,
          nullif(trim(p_colour), ''),
          nullif(upper(trim(p_mother_tag)), ''), v_ph)
  returning id into v_id;

  update tags set status = 'assigned', farm_id = v_farm where id = t.id;

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
  values (v_farm, me.id, 'register_cattle', 'cattle', v_id,
          jsonb_build_object('tag_code', t.tag_code, 'lat', p_lat, 'lng', p_lng,
                             'breed_code', p_breed_code, 'mother_tag', p_mother_tag));
  return v_id;
end $function$;

-- ---------- tap page state ----------

CREATE OR REPLACE FUNCTION public.public_tag_state(p_tag_code text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case
    when t.id is null then null
    when t.paused_at is not null or coalesce(f.status, 'active') <> 'active' then 'paused'
    when t.status in ('blank', 'written', 'recycled')
         and not exists (select 1 from cattle c
                          where c.tag_id = t.id or c.tag_code = t.tag_code) then 'new'
  end
  from (select 1) one
  left join tags t on t.tag_code = p_tag_code
  left join farms f on f.id = t.farm_id
$function$;

-- ---------- "Ферм солих": a farm, or the stock (null) ----------

CREATE OR REPLACE FUNCTION public.admin_assign_tags(p_codes text[], p_farm_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_moved int;
begin
  if not is_super() then raise exception 'Зөвхөн ерөнхий админ.'; end if;
  if p_farm_id is not null and not exists (select 1 from farms where id = p_farm_id) then
    raise exception 'Ферм олдсонгүй.';
  end if;

  update tags t set farm_id = p_farm_id
  where t.tag_code = any(p_codes)
    and t.farm_id is distinct from p_farm_id
    and t.status not in ('assigned', 'retired')
    and not exists (select 1 from cattle c
                    where c.tag_id = t.id or c.tag_code = t.tag_code);
  get diagnostics v_moved = row_count;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (p_farm_id, auth.uid(), 'tags_assign_farm', 'tags', null,
          jsonb_build_object('codes', to_jsonb(p_codes), 'moved', v_moved));

  return jsonb_build_object('moved', v_moved,
                            'skipped', coalesce(array_length(p_codes, 1), 0) - v_moved);
end $function$;

-- ---------- "+ Таг үүсгэх": the stock is allowed ----------

CREATE OR REPLACE FUNCTION public.admin_create_tags(p_prefix text, p_from integer, p_to integer, p_farm_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_prefix   text := upper(trim(coalesce(p_prefix, '')));
  v_existing int;
  v_ex_first text;
  v_ex_last  text;
  v_created  int := 0;
  v_batches  int := 0;
  v_new_first text;
  v_new_last  text;
  seg        record;
begin
  if not coalesce(is_super(), false) then raise exception 'Зөвхөн ерөнхий админ.'; end if;
  if v_prefix !~ '^[A-Z]{1,6}$' then raise exception 'Угтвар зөвхөн латин үсэг (жишээ: YT).'; end if;
  if p_from is null or p_to is null or p_from < 0 or p_to < p_from then
    raise exception 'Дугаарын хүрээ буруу.';
  end if;
  if p_to > 999999 then raise exception 'Дугаар 999999-аас их байж болохгүй.'; end if;
  if p_to - p_from + 1 > 2000 then raise exception 'Нэг удаад 2000-аас ихгүй таг.'; end if;
  if p_farm_id is not null and not exists (select 1 from farms where id = p_farm_id) then
    raise exception 'Ферм олдсонгүй.';
  end if;

  -- what already exists (in any farm)
  select count(*), min(t.tag_code), max(t.tag_code)
    into v_existing, v_ex_first, v_ex_last
    from tags t
   where t.tag_code in (select v_prefix || '-' || lpad(n::text, 6, '0') from generate_series(p_from, p_to) n);

  -- a new batch for every gap (numbers not inside any existing batch)
  for seg in
    select min(n) as s, max(n) as e
      from (select n, n - row_number() over (order by n) as grp
              from generate_series(p_from, p_to) n
             where not exists (select 1 from tag_batches b
                                where b.prefix = v_prefix
                                  and n between b.range_start and b.range_end)) x
     group by grp
     order by 1
  loop
    insert into tag_batches (farm_id, code, prefix, range_start, range_end, status)
    values (p_farm_id, v_prefix || '-' || seg.s || '-' || seg.e, v_prefix, seg.s, seg.e, 'issued');
    v_batches := v_batches + 1;
  end loop;

  -- every missing number, in the batch that covers it
  with ins as (
    insert into tags (farm_id, batch_id, tag_code, qr_slug, status)
    select p_farm_id,
           (select b.id from tag_batches b
             where b.prefix = v_prefix and n between b.range_start and b.range_end
             order by b.range_start limit 1),
           v_prefix || '-' || lpad(n::text, 6, '0'),
           substr(replace(gen_random_uuid()::text, '-', ''), 1, 12),
           'blank'
      from generate_series(p_from, p_to) n
    on conflict (tag_code) do nothing
    returning tag_code
  )
  select count(*), min(tag_code), max(tag_code) into v_created, v_new_first, v_new_last from ins;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (p_farm_id, auth.uid(), 'tags_create', 'tags', null,
          jsonb_build_object('prefix', v_prefix, 'from', p_from, 'to', p_to,
                             'created', v_created, 'already_existed', v_existing,
                             'new_batches', v_batches));

  return jsonb_build_object(
    'created', v_created, 'created_first', v_new_first, 'created_last', v_new_last,
    'skipped', v_existing, 'existing_first', v_ex_first, 'existing_last', v_ex_last,
    'new_batches', v_batches);
end $function$;

-- ---------- replace a lost tag: a stock tag joins the animal's farm ----------

CREATE OR REPLACE FUNCTION public.admin_replace_tag(p_cattle_id uuid, p_new_tag_code text, p_old_status text DEFAULT 'lost'::text, p_reason text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c        record;
  nt       record;
  v_old    text;
  v_old_id uuid;
begin
  select id, farm_id, tag_id, tag_code into c from cattle where id = p_cattle_id for update;
  if not found then raise exception 'Мал олдсонгүй.'; end if;
  if not coalesce(is_super() or (my_role() = 'farm_admin' and c.farm_id = my_farm()), false) then
    raise exception 'Зөвхөн админ таг солино.';
  end if;
  if p_old_status not in ('lost', 'retired') then raise exception 'Хуучин тагийн төлөв буруу.'; end if;

  select * into nt from tags where tag_code = upper(trim(p_new_tag_code)) for update;
  if not found then raise exception 'Шинэ таг олдсонгүй: %', upper(trim(p_new_tag_code)); end if;
  if nt.tag_code = c.tag_code then raise exception 'Энэ таг аль хэдийн энэ малд байна.'; end if;
  if nt.farm_id is not null and nt.farm_id <> c.farm_id then
    raise exception 'Шинэ таг өөр фермийнх. Эхлээд "Тагууд" хэсгээс энэ фермд оноо.';
  end if;
  if nt.status not in ('blank', 'written', 'recycled')
     or exists (select 1 from cattle x where x.tag_id = nt.id or x.tag_code = nt.tag_code) then
    raise exception 'Шинэ таг чөлөөтэй биш (ашиглагдсан, алдагдсан эсвэл хасагдсан).';
  end if;

  v_old := c.tag_code;
  v_old_id := coalesce(c.tag_id, (select id from tags where tag_code = c.tag_code));

  -- the animal takes the new tag; its history stays on cattle.id
  update cattle set tag_id = nt.id, tag_code = nt.tag_code where id = c.id;
  update tags set status = 'assigned', farm_id = c.farm_id where id = nt.id;

  -- the old tag is out of use for good
  if v_old_id is not null then
    update tags
       set status = p_old_status,
           retired_at = case when p_old_status = 'retired' then now() else retired_at end,
           retire_reason = coalesce(nullif(trim(p_reason), ''), retire_reason)
     where id = v_old_id;
  end if;

  -- keep family links pointing at the animal's current tag
  if v_old is not null then
    update cattle set mother_tag = nt.tag_code where mother_tag = v_old;
    update repro_events set sire_tag = nt.tag_code where sire_tag = v_old;
  end if;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (c.farm_id, auth.uid(), 'tag_replace', 'cattle', c.id,
          jsonb_build_object('old_tag', v_old, 'new_tag', nt.tag_code,
                             'old_status', p_old_status, 'reason', p_reason));
end $function$;

-- ---------- delete a farm: its tags go to the stock ----------

CREATE OR REPLACE FUNCTION public.delete_farm(p_farm_id uuid, p_force boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  f record; r record;
  n_cattle int; n_users int; n_tags int;
  v_moved_tags int := 0; v_moved_batches int := 0;
  v_users_deleted int := 0; v_users_off int := 0; v_to_stock int := 0;
  t text;
begin
  if not coalesce(is_super(), false) then raise exception 'Super admin only'; end if;

  select * into f from farms where id = p_farm_id;
  if not found then raise exception 'Farm not found'; end if;

  select count(*) into n_cattle from cattle   where farm_id = p_farm_id;
  select count(*) into n_users  from profiles where farm_id = p_farm_id;
  select count(*) into n_tags   from tags     where farm_id = p_farm_id;

  -- (tags no longer count: they are kept, in the stock)
  if not p_force and (n_cattle > 0 or n_users > 0) then
    raise exception 'Farm has % animals and % users. Archive it, or pass force.',
      n_cattle, n_users;
  end if;

  perform set_config('yaktag.photo_admin', 'on', true);   -- locked photos go too

  -- a tag of this farm on another farm's animal goes with the animal
  update tags tg set farm_id = c.farm_id
    from cattle c
   where c.tag_id = tg.id and tg.farm_id = p_farm_id and c.farm_id <> p_farm_id;
  get diagnostics v_moved_tags = row_count;

  -- records filed under this farm for animals that live elsewhere now
  foreach t in array array['milk_yield', 'health_events', 'repro_events', 'scan_events',
                           'public_scans', 'cattle_photos']
  loop
    if to_regclass('public.' || t) is not null then
      execute format('update public.%I x set farm_id = c.farm_id from public.cattle c
                       where x.cattle_id = c.id and x.farm_id = $1 and c.farm_id <> $1', t)
        using p_farm_id;
    end if;
  end loop;
  update ownership_transfers set from_farm_id = null
   where from_farm_id = p_farm_id
     and cattle_id not in (select id from cattle where farm_id = p_farm_id);
  update ownership_transfers o set farm_id = c.farm_id
    from cattle c
   where o.cattle_id = c.id and o.farm_id = p_farm_id and c.farm_id <> p_farm_id;

  -- this farm's animals and everything recorded for them
  delete from ownership_transfers
   where farm_id = p_farm_id or cattle_id in (select id from cattle where farm_id = p_farm_id);
  foreach t in array array['milk_yield', 'health_events', 'repro_events', 'scan_events',
                           'public_scans', 'cattle_photos']
  loop
    if to_regclass('public.' || t) is not null then
      execute format('delete from public.%I where farm_id = $1
                         or cattle_id in (select id from public.cattle where farm_id = $1)', t)
        using p_farm_id;
    end if;
  end loop;
  delete from notify_log where cattle_id in (select id from cattle where farm_id = p_farm_id);
  delete from cattle where farm_id = p_farm_id;

  -- its tags go to the stock (no farm): the numbers and chips stay usable.
  -- A tag whose animal was just deleted can carry a new animal again.
  update tags set farm_id = null,
                  status = case when status = 'assigned' then 'recycled' else status end
   where farm_id = p_farm_id;
  get diagnostics v_to_stock = row_count;

  -- its batches: kept while they hold tags (with the farm that has most of
  -- them, else no farm); an empty batch is deleted
  for r in select b.id,
                  exists (select 1 from tags t2 where t2.batch_id = b.id) as has_tags,
                  (select t2.farm_id from tags t2 where t2.batch_id = b.id and t2.farm_id is not null
                    group by t2.farm_id order by count(*) desc limit 1) as to_farm
             from tag_batches b where b.farm_id = p_farm_id
  loop
    if not r.has_tags then
      delete from tag_batches where id = r.id;
    else
      update tag_batches set farm_id = r.to_farm where id = r.id;
      v_moved_batches := v_moved_batches + 1;
    end if;
  end loop;

  -- its users. A super admin or Админ linked to this farm only loses the
  -- link — never his login (nor the person pressing the button).
  for r in select id, role from profiles where farm_id = p_farm_id loop
    if r.id = auth.uid() or r.role in ('super_admin', 'admin') then
      update profiles set farm_id = null where id = r.id;
      continue;
    end if;
    begin
      delete from profiles where id = r.id;
      v_users_deleted := v_users_deleted + 1;
    exception when foreign_key_violation then
      update profiles set status = 'disabled', active = false, farm_id = null where id = r.id;
      v_users_off := v_users_off + 1;
    end;
  end loop;

  update audit_log set farm_id = null where farm_id = p_farm_id;
  delete from farms where id = p_farm_id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (null, auth.uid(), 'farm_delete', 'farms', p_farm_id,
          jsonb_build_object('code', f.code, 'name', f.name, 'cattle', n_cattle,
                             'users', n_users, 'tags', n_tags, 'forced', p_force,
                             'users_switched_off', v_users_off, 'tags_to_stock', v_to_stock,
                             'tags_moved', v_moved_tags, 'batches_moved', v_moved_batches));

  perform set_config('yaktag.photo_admin', 'off', true);
  return jsonb_build_object('cattle', n_cattle, 'tags', 0, 'tags_to_stock', v_to_stock,
                            'users_deleted', v_users_deleted, 'users_switched_off', v_users_off,
                            'tags_moved', v_moved_tags, 'batches_moved', v_moved_batches);
end $function$;

-- ---------- dashboard tag list: stock tags too (farm columns empty) ----------
create or replace view public.admin_tag_list with (security_invoker = on) as
 select t.id, t.tag_code, t.status, t.nfc_uid, t.protected, t.written_at, t.created_at,
        t.retired_at, t.retire_reason, t.farm_id,
        f.code as farm_code, f.name as farm_name, b.code as batch_code,
        c.id as cattle_id, c.status as cattle_status, p.full_name as owner_name,
        case
          when c.id is not null then 'assigned'::text
          when t.status = any (array['lost'::text, 'retired'::text]) then t.status
          when t.nfc_uid is not null or (t.status = any (array['written'::text, 'recycled'::text])) then 'written'::text
          else 'blank'::text
        end as stage,
        t.paused_at, t.pause_note
   from tags t
   left join farms f on f.id = t.farm_id
   left join tag_batches b on b.id = t.batch_id
   left join cattle c on c.tag_id = t.id
   left join profiles p on p.id = c.owner_id;

notify pgrst, 'reload schema';

commit;
