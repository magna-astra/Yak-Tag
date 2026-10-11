-- ============================================================
-- YAK-TAG — schema patch v49
--
-- 1. A new account level, "Админ" (role 'admin', no farm of its own):
--    · creates farms and users (малчин / ферм админ) and edits them;
--    · sees everything of the farms HE created — animals, tags, scans,
--      milk, health, photos, users — and nothing of other farms;
--    · never deletes, never pauses, never sees the system history (Түүх).
--    The super admin still sees and controls everything.
-- 2. Pause ("түр зогсоох"): the super admin can pause single tags (and,
--    as before, a whole farm with "Түр хаах"). A paused tag's page says
--    "Энэ таг түр зогсоогдсон. Админд хандана уу" to everyone, and no
--    new data can be added to that animal until it is switched back on.
--    History is kept. The farm's people get a Telegram message.
-- 3. Any new (printed, unused) tag can be registered by any herder; the
--    tag moves to the herder's farm.
-- 4. Deleting a farm works again (it failed on tag_batches) and removes
--    everything of that farm. Users who already have history elsewhere
--    are switched off instead of deleted, so no record is lost.
--
-- Safe on the live project and safe to run twice. All or nothing: if
-- any line fails, nothing is changed.
-- ============================================================

begin;

do $$
begin
  if to_regprocedure('public.is_super()') is null or to_regclass('public.tag_batches') is null
     or to_regclass('public.telegram_links') is null then
    raise exception 'Wrong database: open the YAK-TAG project oxfbxqclqfglpzgzizhq and run again.';
  end if;
end $$;

-- ---------- 1. the Админ role ----------
do $$
declare r record;
begin
  -- the old role list and the old "everyone but the super admin has a
  -- farm" rule, whatever their names are on this database
  for r in select conname from pg_constraint
            where conrelid = 'public.profiles'::regclass and contype = 'c'
              and (pg_get_constraintdef(oid) like '%herder%'
                   or pg_get_constraintdef(oid) like '%farm_id IS NOT NULL%')
  loop
    execute format('alter table public.profiles drop constraint %I', r.conname);
  end loop;
end $$;
alter table public.profiles add constraint profiles_role_check
  check (role in ('super_admin', 'admin', 'farm_admin', 'herder'));
-- a switched-off user may be left without a farm (farm deleted)
alter table public.profiles add constraint farm_required
  check (role in ('super_admin', 'admin') or farm_id is not null or status = 'disabled');

alter table public.farms add column if not exists created_by uuid
  references public.profiles(id) on delete set null;
alter table public.tags add column if not exists paused_at  timestamptz;
alter table public.tags add column if not exists paused_by  uuid references public.profiles(id) on delete set null;
alter table public.tags add column if not exists pause_note text;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role = 'admin' from profiles
                    where id = auth.uid() and status = 'active'), false)
$$;

-- the farms the signed-in Админ created ({} for everyone else)
create or replace function public.admin_farm_ids() returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(f.id), '{}')
  from farms f join profiles p on p.id = f.created_by
  where p.id = auth.uid() and p.role = 'admin' and p.status = 'active'
$$;

create or replace function public.admin_owns_farm(p_farm uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_farm is not null and p_farm = any(admin_farm_ids())
$$;

-- photo folders are farm-<uuid>/cow-<uuid>/...
create or replace function public.admin_farm_folders() returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg('farm-' || x::text), '{}') from unnest(admin_farm_ids()) x
$$;

revoke all on function public.is_admin(), public.admin_farm_ids(), public.admin_owns_farm(uuid),
                       public.admin_farm_folders() from public, anon;
grant execute on function public.is_admin(), public.admin_farm_ids(), public.admin_owns_farm(uuid),
                          public.admin_farm_folders() to authenticated;

-- Telegram to a farm's people and the Админ who created it (not to the
-- person who pressed the button). Never fails the caller.
create or replace function public.notify_farm(p_farm uuid, p_text text) returns integer
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  if app_secret('telegram_token') is null then return 0; end if;
  for r in
    select distinct l.chat_id
      from telegram_links l
      join profiles p on p.id = l.profile_id and p.status = 'active'
     where (p.farm_id = p_farm
            or p.id = (select created_by from farms where id = p_farm))
       and p.id is distinct from auth.uid()
  loop
    perform tg_send(r.chat_id, p_text);
    n := n + 1;
  end loop;
  return n;
exception when others then
  return n;
end $$;
revoke all on function public.notify_farm(uuid, text) from public, anon, authenticated;

-- ---------- what an Админ can read: his own farms, all of it ----------
-- Extra policies only; Postgres ORs them with the existing ones, so
-- nobody else's access changes. The farm list is worked out once per
-- query (the "select" around the function).
do $$
declare t text;
begin
  foreach t in array array['profiles', 'cattle', 'cattle_photos', 'health_events', 'milk_yield',
                           'public_scans', 'repro_events', 'scan_events', 'tag_batches', 'tags']
  loop
    if to_regclass('public.' || t) is not null then
      execute format('drop policy if exists admin_read on public.%I', t);
      execute format('create policy admin_read on public.%I for select to authenticated
                        using (farm_id = any ((select public.admin_farm_ids())::uuid[]))', t);
    end if;
  end loop;
end $$;

drop policy if exists admin_read on public.farms;
create policy admin_read on public.farms for select to authenticated
  using (id = any ((select public.admin_farm_ids())::uuid[]));

drop policy if exists admin_read on public.ownership_transfers;
create policy admin_read on public.ownership_transfers for select to authenticated
  using (farm_id = any ((select public.admin_farm_ids())::uuid[])
         or from_farm_id = any ((select public.admin_farm_ids())::uuid[]));

-- animal photos of his farms (also ones taken before the animal moved in)
drop policy if exists admin_photos_read on storage.objects;
create policy admin_photos_read on storage.objects for select to authenticated
  using (bucket_id in ('cattle-photos', 'cattle-public')
         and (select public.is_admin())
         and ((storage.foldername(name))[1] = any ((select public.admin_farm_folders())::text[])
              or exists (select 1 from public.cattle c
                          where (storage.foldername(objects.name))[2] = 'cow-' || c.id::text
                            and c.farm_id = any ((select public.admin_farm_ids())::uuid[]))));

-- ---------- 2. pause: nothing new is saved for a paused tag ----------
create or replace function public.refuse_when_paused() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  j        jsonb := to_jsonb(new);
  v_cattle uuid;
  v_tag    uuid;
begin
  if coalesce(is_super(), false) then return new; end if;
  v_cattle := case when tg_table_name = 'cattle' then (j->>'id')::uuid
                   else nullif(j->>'cattle_id', '')::uuid end;
  v_tag    := nullif(j->>'tag_id', '')::uuid;
  if exists (select 1 from cattle c join tags t on t.id = c.tag_id
              where c.id = v_cattle and t.paused_at is not null)
     or exists (select 1 from tags t where t.id = v_tag and t.paused_at is not null)
     or exists (select 1 from cattle c join farms f on f.id = c.farm_id
                 where c.id = v_cattle and f.status <> 'active') then
    raise exception 'Энэ таг түр зогсоогдсон. Админд хандана уу.' using errcode = 'check_violation';
  end if;
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['milk_yield', 'health_events', 'repro_events', 'cattle_photos',
                           'scan_events', 'ownership_transfers', 'cattle']
  loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists paused_guard on public.%I', t);
      execute format('create trigger paused_guard before %s on public.%I
                        for each row execute function public.refuse_when_paused()',
                     case t when 'cattle' then 'update'
                            when 'cattle_photos' then 'insert'
                            when 'scan_events' then 'insert'
                            when 'ownership_transfers' then 'insert'
                            else 'insert or update' end, t);
    end if;
  end loop;
end $$;


-- ---------- public tap page: a paused tag shows nothing (v42 + v49) ----------

CREATE OR REPLACE FUNCTION public.public_tag_lookup(p_tag_code text)
 RETURNS TABLE(tag_code text, photo_path text, has_phone boolean, phone text, is_lost boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  LIMIT_PER_HOUR constant int := 120;
  r        record;
  v_found  boolean;
  v_recent int;
  v_caller text;
  v_n      int;
begin
  -- per-visitor limit first: over it, answer exactly like an unknown tag
  v_caller := scan_caller_hash();
  if v_caller is not null then
    insert into lookup_rate as lr (caller_hash, hour, n)
    values (v_caller, date_trunc('hour', now()), 1)
    on conflict (caller_hash, hour) do update set n = lr.n + 1
    returning lr.n into v_n;
    if random() < 0.01 then
      delete from lookup_rate where hour < now() - interval '2 days';
    end if;
    if v_n > LIMIT_PER_HOUR then
      return;
    end if;
  end if;

  select c.tag_code, c.public_photo_path,
         (c.contact_phone is not null) as has_phone,
         c.contact_phone,
         (c.reported_lost_at is not null or c.status in ('lost','stolen')) as is_lost
    into r
  from cattle c
  join farms f on f.id = c.farm_id
  where c.tag_code = p_tag_code
    and f.status = 'active'
    and not exists (select 1 from tags tg where tg.id = c.tag_id and tg.paused_at is not null);
  v_found := found;                 -- capture before any other statement

  select count(*) into v_recent
  from lookup_attempts
  where at > now() - interval '1 hour';

  if v_recent < 500 then
    insert into lookup_attempts (tag_code, found)
    values (left(p_tag_code, 40), v_found);
  end if;

  -- Roughly 1 lookup in 100 clears out old rows. No pg_cron needed.
  if random() < 0.01 then
    delete from lookup_attempts where at < now() - interval '30 days';
  end if;

  if not v_found then return; end if;

  tag_code   := r.tag_code;
  photo_path := r.public_photo_path;
  has_phone  := r.has_phone;
  phone      := r.contact_phone;
  is_lost    := r.is_lost;
  return next;
end $function$;

-- ---------- strangers' taps: nothing saved while paused (v24 + v49) ----------

CREATE OR REPLACE FUNCTION public.record_public_scan(p_tag_code text, p_lat numeric DEFAULT NULL::numeric, p_lng numeric DEFAULT NULL::numeric, p_accuracy numeric DEFAULT NULL::numeric, p_user_agent text DEFAULT NULL::text, p_client_uuid uuid DEFAULT NULL::uuid, p_scanned_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  LIMIT_CALLER_TAG   constant int := 3;
  LIMIT_CALLER_TOTAL constant int := 200;
  LIMIT_TAG          constant int := 20;

  c        record;
  v_id     uuid;
  v_when   timestamptz;
  v_late   boolean;
  v_caller text;
  v_lost   boolean;
  n        int;
begin
  select id, farm_id, status, reported_lost_at into c
  from cattle where tag_code = p_tag_code;
  if not found then return null; end if;
  -- paused tag or farm (v49): nothing is saved
  if exists (select 1 from farms f where f.id = c.farm_id and f.status <> 'active')
     or exists (select 1 from cattle cc join tags tg on tg.id = cc.tag_id
                 where cc.id = c.id and tg.paused_at is not null) then
    return null;
  end if;
  v_lost := (c.reported_lost_at is not null or c.status in ('lost','stolen'));

  -- A retry of a scan we already have: same answer, and it does not
  -- count against any limit.
  if p_client_uuid is not null then
    select id into v_id from public_scans where client_uuid = p_client_uuid;
    if found then return v_id; end if;
  end if;

  v_caller := scan_caller_hash();

  if v_caller is not null then
    select count(*) into n from public_scans
    where caller_hash = v_caller and received_at > now() - interval '1 hour';
    if n >= LIMIT_CALLER_TOTAL then return null; end if;

    select count(*) into n from public_scans
    where caller_hash = v_caller and cattle_id = c.id
      and received_at > now() - interval '1 hour';
    if n >= LIMIT_CALLER_TAG then return null; end if;
  end if;

  select count(*) into n from public_scans
  where cattle_id = c.id
    and coalesce(received_at, scanned_at) > now() - interval '1 hour';
  if n >= LIMIT_TAG then
    -- Full for this hour. For a lost or stolen animal, a caller we
    -- have not seen on it this hour still gets through: that may be
    -- the one real finder.
    if not (v_lost and v_caller is not null and not exists (
              select 1 from public_scans
              where cattle_id = c.id and caller_hash = v_caller
                and received_at > now() - interval '1 hour')) then
      return null;          -- silently ignored, as in v20
    end if;
  end if;

  if p_scanned_at is not null
     and p_scanned_at between now() - interval '7 days'
                          and now() + interval '5 minutes' then
    v_when := least(p_scanned_at, now());
  else
    v_when := now();
  end if;
  v_late := v_when < now() - interval '2 minutes';

  insert into public_scans (cattle_id, farm_id, lat, lng, accuracy_m, user_agent,
                            was_lost, scanned_at, received_at, client_uuid,
                            was_offline, caller_hash)
  values (c.id, c.farm_id, p_lat, p_lng, p_accuracy, left(p_user_agent, 200),
          v_lost, v_when, now(), p_client_uuid, v_late, v_caller)
  on conflict (client_uuid) where client_uuid is not null do nothing
  returning id into v_id;

  if v_id is null and p_client_uuid is not null then
    select id into v_id from public_scans where client_uuid = p_client_uuid;
  end if;

  return v_id;
end $function$;

-- ---------- registration: any new tag, moves to the herder's farm (v28 + v49) ----------

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
  from tags tg join farms f on f.id = tg.farm_id
  where tg.tag_code = p_tag_code
  for update of tg;
  if not found then raise exception 'Таг олдсонгүй: %', p_tag_code; end if;

  if exists (select 1 from cattle c where c.tag_id = t.id or c.tag_code = t.tag_code) then
    raise exception 'Энэ таг дээр мал аль хэдийн бүртгэгдсэн байна.';
  end if;
  if t.paused_at is not null or t.farm_status <> 'active' then
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

-- ---------- lost alert: also the farm's Админ (v38 + v49) ----------

CREATE OR REPLACE FUNCTION public.tg_alert_lost_scan(p_cattle_id uuid, p_lat double precision, p_lng double precision, p_accuracy double precision, p_when timestamp with time zone, p_by uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c      record;
  r      record;
  v_site text := coalesce(app_secret('site_url'), 'https://magna-astra.github.io/Yak-Tag');
  v_who  text;
  v_txt  text;
  n      int := 0;
begin
  if app_secret('telegram_token') is null then return 0; end if;

  select ca.id, ca.tag_code, ca.farm_id, ca.owner_id, ca.breed, p.full_name as owner_name
    into c
  from cattle ca left join profiles p on p.id = ca.owner_id
  where ca.id = p_cattle_id;
  if not found then return 0; end if;

  v_who := case when p_by is null then 'танихгүй хүн (нийтийн хуудаснаас)'
                else coalesce((select full_name from profiles where id = p_by), 'хэрэглэгч')
                     || ' (YAK-TAG хэрэглэгч)' end;

  v_txt := '⚠ АЛГА БОЛСОН МАЛ УНШУУЛАГДЛАА' || E'\n\n'
        || c.tag_code || coalesce(' · ' || c.breed, '') || E'\n'
        || 'Эзэмшигч: ' || coalesce(c.owner_name, '—') || E'\n'
        || 'Хэзээ: ' || to_char(coalesce(p_when, now()) at time zone 'Asia/Ulaanbaatar',
                                'YYYY/MM/DD HH24:MI') || E'\n'
        || 'Хэн: ' || v_who || E'\n'
        || case when p_lat is not null and p_lng is not null
                then 'Хаана: https://maps.google.com/?q='
                     || round(p_lat::numeric, 6) || ',' || round(p_lng::numeric, 6)
                     || coalesce(' (±' || round(p_accuracy)::text || ' м)', '')
                else 'Хаана: байршил тодорхойгүй (уншуулсан хүн байршлаа зөвшөөрөөгүй)' end
        || E'\n\n' || 'Дэлгэрэнгүй: ' || v_site || '/cow.html?tag=' || c.tag_code;

  -- owner, the farm's admins, super admins — once per Telegram chat,
  -- and never the person who tapped
  for r in
    select distinct l.chat_id
    from telegram_links l
    join profiles p on p.id = l.profile_id and p.status = 'active'
    where (p.id = c.owner_id
           or (p.role = 'farm_admin' and p.farm_id = c.farm_id)
           or (p.role = 'admin' and exists (select 1 from farms af
                                             where af.id = c.farm_id and af.created_by = p.id))
           or p.role = 'super_admin')
      and l.profile_id is distinct from p_by
  loop
    continue when exists (
      select 1 from notify_log
      where cattle_id = c.id and chat_id = r.chat_id and kind = 'lost_scan'
        and sent_at > now() - interval '10 minutes');
    insert into notify_log (cattle_id, chat_id, kind, request_id)
    values (c.id, r.chat_id, 'lost_scan', tg_send(r.chat_id, v_txt));
    n := n + 1;
  end loop;
  return n;
end $function$;

-- ---------- farm edit: super admin, or the Админ who created it ----------

CREATE OR REPLACE FUNCTION public.admin_update_farm(p_farm_id uuid, p_code text, p_name text, p_aimag text, p_soum text, p_lat double precision, p_lng double precision)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not (coalesce(is_super(), false) or admin_owns_farm(p_farm_id)) then
    raise exception 'Энэ фермийг засах эрхгүй.';
  end if;
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
end $function$;

-- ---------- tap page state: 'new', 'paused' or nothing (v42 + v49) ----------
create or replace function public.public_tag_state(p_tag_code text) returns text
language sql stable security definer set search_path = public as $$
  select case
    when t.id is null then null
    when t.paused_at is not null or f.status <> 'active' then 'paused'
    when t.status in ('blank', 'written', 'recycled')
         and not exists (select 1 from cattle c
                          where c.tag_id = t.id or c.tag_code = t.tag_code) then 'new'
  end
  from (select 1) one
  left join tags t on t.tag_code = p_tag_code
  left join farms f on f.id = t.farm_id
$$;

-- ---------- what the registration page shows (v28 + v49) ----------
-- No more "other farm": the animal joins the signed-in herder's farm.
create or replace function public.tag_registration_info(p_tag_code text)
returns table(tag_code text, farm_name text, farm_code text, can_register boolean, reason text)
language plpgsql stable security definer set search_path = public as $$
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
  from tags tg join farms f on f.id = tg.farm_id
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
  elsif t.paused_at is not null or t.farm_status <> 'active' then
    reason := 'paused';
  elsif t.status not in ('blank', 'written', 'recycled') then
    reason := 'unavailable';
  elsif me.role not in ('herder', 'farm_admin', 'super_admin')
        or (me.role <> 'super_admin' and me.farm_id is null) then
    reason := 'no_farm';
  else
    reason := 'ok';
    can_register := true;
  end if;
  return next;
end $$;

-- ---------- farms: the super admin or an Админ creates them ----------
create or replace function public.create_farm(
  p_code text, p_name text, p_aimag text, p_soum text,
  p_lat numeric default null, p_lng numeric default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not (coalesce(is_super(), false) or coalesce(is_admin(), false)) then
    raise exception 'Ферм үүсгэх эрхгүй.';
  end if;

  insert into farms (code, name, aimag, soum, center_lat, center_lng, status, created_by)
  values (p_code, p_name, p_aimag, p_soum, p_lat, p_lng, 'active', auth.uid())
  returning id into v_id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (v_id, auth.uid(), 'farm_create', 'farms', v_id,
          jsonb_build_object('code', p_code, 'name', p_name));
  return v_id;
end $$;

-- the super admin hands a farm to an Админ (or takes it back: null)
create or replace function public.admin_set_farm_owner(p_farm_id uuid, p_admin_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(is_super(), false) then raise exception 'Зөвхөн ерөнхий админ.'; end if;
  if not exists (select 1 from farms where id = p_farm_id) then raise exception 'Farm not found'; end if;
  if p_admin_id is not null
     and not exists (select 1 from profiles where id = p_admin_id and role = 'admin') then
    raise exception 'Сонгосон хүн Админ эрхтэй биш.';
  end if;
  update farms set created_by = p_admin_id where id = p_farm_id;
  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (p_farm_id, auth.uid(), 'farm_owner', 'farms', p_farm_id,
          jsonb_build_object('admin', p_admin_id));
end $$;

-- ---------- users: the super admin, or an Админ for his own farms ----------
create or replace function public.admin_update_profile(
  p_profile_id uuid, p_full_name text default null, p_phone text default null,
  p_role text default null, p_farm_id uuid default null, p_active boolean default null
) returns void language plpgsql security definer set search_path = public as $$
declare
  v_super boolean := coalesce(is_super(), false);
  t       record;
  v_role  text;
  v_farm  uuid;
begin
  select id, role, farm_id into t from profiles where id = p_profile_id;
  if not found then raise exception 'User not found'; end if;

  if not v_super then
    if not coalesce(is_admin(), false) then raise exception 'Super admin only'; end if;
    if t.role not in ('herder', 'farm_admin') or not admin_owns_farm(t.farm_id) then
      raise exception 'Энэ хэрэглэгчийг засах эрхгүй.';
    end if;
    if p_role is not null and p_role not in ('herder', 'farm_admin') then
      raise exception 'Админ зөвхөн малчин, ферм админ эрх өгнө.';
    end if;
    if p_farm_id is not null and not admin_owns_farm(p_farm_id) then
      raise exception 'Зөвхөн өөрийн үүсгэсэн фермийг сонгоно.';
    end if;
    p_active := null;            -- switching a login off is the super admin's
  end if;

  v_role := coalesce(p_role, t.role);
  v_farm := case when v_role = 'admin' then null else coalesce(p_farm_id, t.farm_id) end;
  if v_role in ('herder', 'farm_admin') and v_farm is null then
    raise exception 'Ферм сонгоно уу.';
  end if;

  update profiles set
    full_name    = coalesce(p_full_name, full_name),
    phone        = coalesce(p_phone, phone),
    public_phone = coalesce(p_phone, public_phone),
    role         = v_role,
    farm_id      = v_farm,
    active       = coalesce(p_active, active)
  where id = p_profile_id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (v_farm, auth.uid(), 'admin_edit_profile', 'profiles', p_profile_id,
          jsonb_build_object('role', p_role, 'farm_id', p_farm_id));
end $$;

-- A user with history (records, animals, past actions) is switched off
-- instead of deleted — history keeps its author. Returns what happened.
drop function if exists public.delete_profile(uuid, boolean);
create function public.delete_profile(p_profile_id uuid, p_force boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare
  p record; n_cattle int; v_done text := 'deleted';
begin
  if not coalesce(is_super(), false) then raise exception 'Super admin only'; end if;
  if p_profile_id = auth.uid() then raise exception 'You cannot delete yourself'; end if;

  select * into p from profiles where id = p_profile_id;
  if not found then raise exception 'User not found'; end if;

  select count(*) into n_cattle from cattle where owner_id = p_profile_id;
  if n_cattle > 0 and not p_force then
    raise exception 'User owns % animals. Reassign them first, or pass force.', n_cattle;
  end if;

  begin
    delete from profiles where id = p_profile_id;
  exception when foreign_key_violation then
    update profiles set status = 'disabled' where id = p_profile_id;
    v_done := 'disabled';
  end;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (p.farm_id, auth.uid(), 'profile_delete', 'profiles', p_profile_id,
          jsonb_build_object('name', p.full_name, 'role', p.role,
                             'cattle_owned', n_cattle, 'forced', p_force, 'result', v_done));
  return v_done;
end $$;
revoke all on function public.delete_profile(uuid, boolean) from public, anon;
grant execute on function public.delete_profile(uuid, boolean) to authenticated;

-- ---------- delete a farm, completely (super admin) ----------
-- Removes the farm's animals with all their records, its tags, batches
-- and users. Things that now belong to another farm are kept and moved
-- there (a tag on another farm's animal, that animal's older records,
-- a batch with another farm's tags). Users with history elsewhere are
-- switched off. The system history stays, without the farm link.
drop function if exists public.delete_farm(uuid, boolean);
create function public.delete_farm(p_farm_id uuid, p_force boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  f record; r record;
  n_cattle int; n_users int; n_tags int;
  v_moved_tags int := 0; v_moved_batches int := 0;
  v_users_deleted int := 0; v_users_off int := 0;
  t text;
begin
  if not coalesce(is_super(), false) then raise exception 'Super admin only'; end if;

  select * into f from farms where id = p_farm_id;
  if not found then raise exception 'Farm not found'; end if;

  select count(*) into n_cattle from cattle   where farm_id = p_farm_id;
  select count(*) into n_users  from profiles where farm_id = p_farm_id;
  select count(*) into n_tags   from tags     where farm_id = p_farm_id;

  if not p_force and (n_cattle > 0 or n_users > 0 or n_tags > 0) then
    if n_tags > 0 then
      raise exception 'Farm has % animals, % users and % tags. Archive it, or pass force.',
        n_cattle, n_users, n_tags;
    end if;
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

  -- its tags
  delete from scan_events where tag_id in (select id from tags where farm_id = p_farm_id);
  delete from tags where farm_id = p_farm_id;

  -- its batches: one still holding another farm's tags moves to that farm
  for r in select b.id,
                  (select t2.farm_id from tags t2 where t2.batch_id = b.id
                    group by t2.farm_id order by count(*) desc limit 1) as to_farm
             from tag_batches b where b.farm_id = p_farm_id
  loop
    if r.to_farm is null then
      delete from tag_batches where id = r.id;
    else
      update tag_batches set farm_id = r.to_farm where id = r.id;
      v_moved_batches := v_moved_batches + 1;
    end if;
  end loop;

  -- its users
  for r in select id from profiles where farm_id = p_farm_id loop
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
                             'users_switched_off', v_users_off,
                             'tags_moved', v_moved_tags, 'batches_moved', v_moved_batches));

  perform set_config('yaktag.photo_admin', 'off', true);
  return jsonb_build_object('cattle', n_cattle, 'tags', n_tags - v_moved_tags,
                            'users_deleted', v_users_deleted, 'users_switched_off', v_users_off,
                            'tags_moved', v_moved_tags, 'batches_moved', v_moved_batches);
end $$;
revoke all on function public.delete_farm(uuid, boolean) from public, anon;
grant execute on function public.delete_farm(uuid, boolean) to authenticated;

-- ---------- pause / resume a whole farm (super admin) ----------
create or replace function public.archive_farm(p_farm_id uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_users jsonb;
begin
  if not coalesce(is_super(), false) then raise exception 'Super admin only'; end if;
  if not exists (select 1 from farms where id = p_farm_id) then raise exception 'Farm not found'; end if;
  if exists (select 1 from farms where id = p_farm_id and status <> 'active') then return; end if;

  -- remembered, so "Сэргээх" switches back on exactly these people
  select coalesce(jsonb_agg(id), '[]'::jsonb) into v_users
    from profiles where farm_id = p_farm_id and status = 'active';

  perform notify_farm(p_farm_id,
    '⏸ ' || (select name from farms where id = p_farm_id)
    || ' ферм түр зогсоогдлоо. Таг уншуулахад "түр зогсоогдсон" гэж гарна.' || E'\n'
    || 'Холбогдох: ' || coalesce((select phone from site_settings where id = 1), 'админ'));

  update farms set status = 'suspended', archived_at = now() where id = p_farm_id;
  update profiles set active = false where farm_id = p_farm_id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (p_farm_id, auth.uid(), 'farm_archive', 'farms', p_farm_id,
          jsonb_build_object('reason', p_reason, 'users', v_users));
end $$;

create or replace function public.restore_farm(p_farm_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_users jsonb;
begin
  if not coalesce(is_super(), false) then raise exception 'Super admin only'; end if;

  select a.detail->'users' into v_users
    from audit_log a
   where a.entity = 'farms' and a.entity_id = p_farm_id and a.action = 'farm_archive'
   order by a.at desc limit 1;

  update farms set status = 'active', archived_at = null where id = p_farm_id;
  -- the people who were on when it was paused (paused before v49: all)
  update profiles set active = true
   where farm_id = p_farm_id and status = 'disabled'
     and (v_users is null or id::text in (select jsonb_array_elements_text(v_users)));

  perform notify_farm(p_farm_id,
    '▶ ' || (select name from farms where id = p_farm_id)
    || ' ферм дахин идэвхжлээ. Таг, бүртгэл хэвийн ажиллана.');

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (p_farm_id, auth.uid(), 'farm_restore', 'farms', p_farm_id, '{}'::jsonb);
end $$;

-- ---------- pause / resume tags (super admin) ----------
create or replace function public.admin_pause_tags(p_codes text[], p_pause boolean, p_note text default null)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_codes text[];
  r       record;
  v_phone text := coalesce((select phone from site_settings where id = 1), 'админ');
begin
  if not coalesce(is_super(), false) then raise exception 'Зөвхөн ерөнхий админ.'; end if;
  if p_pause is null then raise exception 'p_pause required'; end if;
  if p_codes is null or cardinality(p_codes) = 0 then return 0; end if;
  if cardinality(p_codes) > 5000 then raise exception 'Нэг удаад 5000-аас ихгүй таг.'; end if;

  with u as (
    update tags
       set paused_at  = case when p_pause then now() end,
           paused_by  = case when p_pause then auth.uid() end,
           pause_note = case when p_pause then nullif(trim(p_note), '') end
     where tag_code = any(p_codes)
       and (paused_at is not null) <> p_pause
    returning tag_code
  )
  select coalesce(array_agg(tag_code order by tag_code), '{}') into v_codes from u;

  if cardinality(v_codes) = 0 then return 0; end if;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (null, auth.uid(), case when p_pause then 'tags_pause' else 'tags_resume' end, 'tags', null,
          jsonb_build_object('count', cardinality(v_codes), 'codes', to_jsonb(v_codes[1:200]),
                             'note', nullif(trim(p_note), '')));

  -- Telegram: the animal's owner, the farm admins, the farm's Админ
  for r in
    select l.chat_id, array_agg(distinct t.tag_code) as codes
      from tags t
      left join cattle c on c.tag_id = t.id
      join profiles p on p.status = 'active'
                     and (p.id = c.owner_id
                          or (p.role = 'farm_admin' and p.farm_id = t.farm_id)
                          or (p.role = 'admin' and p.id = (select created_by from farms where id = t.farm_id)))
      join telegram_links l on l.profile_id = p.id
     where t.tag_code = any(v_codes)
       and p.id is distinct from auth.uid()
     group by l.chat_id
  loop
    perform tg_send(r.chat_id,
      case when p_pause
           then '⏸ Таг түр зогсоогдлоо: ' || array_to_string(r.codes[1:20], ', ')
                || case when cardinality(r.codes) > 20 then ' … (' || cardinality(r.codes) || ')' else '' end
                || E'\n' || 'Сэргээх хүртэл шинэ мэдээлэл нэмэх боломжгүй. Холбогдох: ' || v_phone
           else '▶ Таг дахин идэвхжлээ: ' || array_to_string(r.codes[1:20], ', ')
                || case when cardinality(r.codes) > 20 then ' … (' || cardinality(r.codes) || ')' else '' end
      end);
  end loop;

  return cardinality(v_codes);
end $$;

revoke all on function public.admin_pause_tags(text[], boolean, text),
                       public.admin_set_farm_owner(uuid, uuid) from public, anon;
grant execute on function public.admin_pause_tags(text[], boolean, text),
                          public.admin_set_farm_owner(uuid, uuid) to authenticated;

-- ---------- dashboard tag list: + pause columns ----------
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
   join farms f on f.id = t.farm_id
   left join tag_batches b on b.id = t.batch_id
   left join cattle c on c.tag_id = t.id
   left join profiles p on p.id = c.owner_id;

-- the dashboard's farm list: + who the farm belongs to
create or replace view public.admin_farms with (security_invoker = on) as
 select f.id, f.code, f.name, f.aimag, f.soum, f.status, f.center_lat, f.center_lng, f.archived_at,
        (select count(*) from cattle c where c.farm_id = f.id) as cattle_count,
        (select count(*) from profiles p where p.farm_id = f.id) as user_count,
        (select count(*) from tags t where t.farm_id = f.id) as tag_count,
        f.created_by,
        (select p.full_name from profiles p where p.id = f.created_by and p.role = 'admin') as admin_name
   from farms f
  order by f.code;

notify pgrst, 'reload schema';

commit;
