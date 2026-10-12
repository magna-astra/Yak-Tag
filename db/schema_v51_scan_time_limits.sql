-- ============================================================
-- YAK-TAG — schema patch v51
-- 1. A stranger's tap made with no signal keeps the RIGHT time even when
--    the phone's clock is wrong: the phone also sends how long ago the tap
--    was (p_age_ms, measured on its own clock). Older pages keep working.
-- 2. The lost-animal Telegram alert says when a tap arrives late
--    ("⏱ Сүлжээгүй үед уншуулсан — HH:MI-д ирсэн").
-- 3. One login can register at most 60 animals per hour; at 50 the super
--    admins get a Telegram warning (stolen password / script protection).
-- 4. The order form also stops at 100 requests per day.
-- Needs v50. Safe on the live project and safe to run twice. All or
-- nothing: if any line fails, nothing is changed.
-- ============================================================

begin;

do $$
begin
  if to_regprocedure('public.admin_pause_tags(text[],boolean,text)') is null then
    raise exception 'Run v49 and v50 first (or wrong database: open project oxfbxqclqfglpzgzizhq).';
  end if;
end $$;

create index if not exists cattle_registered_by_idx on public.cattle (registered_by, created_at);

-- the old 7-argument version goes; the new one accepts the same calls
-- (p_age_ms is optional), so pages already on phones keep working
drop function if exists public.record_public_scan(text, numeric, numeric, numeric, text, uuid, timestamptz);

-- ---------- stranger's tap: right time even with a wrong phone clock ----------

CREATE OR REPLACE FUNCTION public.record_public_scan(p_tag_code text, p_lat numeric DEFAULT NULL::numeric, p_lng numeric DEFAULT NULL::numeric, p_accuracy numeric DEFAULT NULL::numeric, p_user_agent text DEFAULT NULL::text, p_client_uuid uuid DEFAULT NULL::uuid, p_scanned_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_age_ms bigint DEFAULT NULL::bigint)
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

  -- v51: how long ago the tap was, measured on the phone's own clock —
  -- right even when that clock is set wrong. Else the phone's time.
  if p_age_ms is not null and p_age_ms between 0 and 7 * 86400000::bigint then
    v_when := now() - p_age_ms * interval '1 millisecond';
  elsif p_scanned_at is not null
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

-- ---------- lost alert: says when a tap arrives late ----------

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
        || case when p_when < now() - interval '5 minutes'
                then '⏱ Сүлжээгүй үед уншуулсан — ' || to_char(now() at time zone 'Asia/Ulaanbaatar', 'HH24:MI')
                     || '-д ирсэн. Байршил нь уншуулсан үеийнх.' || E'\n'
                else '' end
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

-- ---------- registration: at most 60 per person per hour ----------

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

  -- v51: at most 60 new animals per person per hour (a stolen password or
  -- a script could otherwise take every blank tag in seconds)
  if me.role <> 'super_admin' and (select count(*) from cattle
       where registered_by = me.id and created_at > now() - interval '1 hour') >= 60 then
    raise exception 'Нэг цагт 60-аас олон мал бүртгэх боломжгүй. Түр хүлээгээд дахин оролдоно уу.';
  end if;

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
  -- v51: the 50th in an hour warns the super admins (once)
  if me.role <> 'super_admin' and (select count(*) from cattle
       where registered_by = me.id and created_at > now() - interval '1 hour') = 50 then
    perform tg_send(l.chat_id,
              '⚠ ' || coalesce((select full_name from profiles where id = me.id), 'Хэрэглэгч')
              || coalesce(' (' || me.phone || ')', '') || ' сүүлийн 1 цагт 50 мал бүртгэлээ.' || E'\n'
              || 'Хэвийн биш бол нууц үгийг нь солиод бүртгэлийг шалгана уу. 60-д хүрвэл 1 цаг хаагдана.')
       from telegram_links l join profiles p on p.id = l.profile_id
      where p.role = 'super_admin' and p.status = 'active';
  end if;
  return v_id;
end $function$;

-- ---------- order form: 100 per day ----------

CREATE OR REPLACE FUNCTION public.submit_order(p_name text, p_phone text, p_qty integer, p_farm text DEFAULT NULL::text, p_place text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_website text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_name  text := left(trim(coalesce(p_name, '')), 80);
  v_phone text := left(trim(coalesce(p_phone, '')), 24);
  v_farm  text := nullif(left(trim(coalesce(p_farm, '')), 120), '');
  v_place text := nullif(left(trim(coalesce(p_place, '')), 120), '');
  v_note  text := nullif(left(trim(coalesce(p_note, '')), 600), '');
  v_hash  text := scan_caller_hash();
  v_id    bigint;
  v_txt   text;
  r       record;
  n       int := 0;
  v_call  text := coalesce((select phone from site_settings where id = 1), '9903 1147');
  v_to    text;
begin
  -- a bot filled the hidden field: pretend success, keep nothing
  if coalesce(trim(p_website), '') <> '' then return true; end if;

  if length(v_name) < 2 then raise exception 'Нэрээ оруулна уу.'; end if;
  if v_phone !~ '^\+?[0-9][0-9 ()-]{6,19}$'
     or length(regexp_replace(v_phone, '[^0-9]', '', 'g')) < 8 then
    raise exception 'Утасны дугаараа зөв оруулна уу (8 оронтой).';
  end if;
  if p_qty is null or p_qty < 1 or p_qty > 100000 then
    raise exception 'Тагийн тоо 1-ээс 100000 хооронд байна.';
  end if;

  if v_hash is not null and (select count(*) from order_requests
       where caller_hash = v_hash and created_at > now() - interval '1 hour') >= 3 then
    raise exception 'Та саяхан захиалга илгээсэн байна. Яаралтай бол % руу залгана уу.', v_call;
  end if;
  if (select count(*) from order_requests where created_at > now() - interval '1 hour') >= 30
     or (select count(*) from order_requests where created_at > now() - interval '1 day') >= 100 then
    raise exception 'Одоогоор хүсэлт их байна. % руу залгана уу.', v_call;
  end if;

  insert into order_requests (name, phone, qty, farm, place, note, caller_hash)
  values (v_name, v_phone, p_qty, v_farm, v_place, v_note, v_hash)
  returning id into v_id;

  -- Telegram to every linked super admin (v38). Any failure here must
  -- not lose the order, which is already saved above.
  begin
    v_txt := '🛒 ШИНЭ ЗАХИАЛГА №' || v_id || E'\n\n'
          || 'Нэр: ' || v_name || E'\n'
          || 'Утас: ' || v_phone || E'\n'
          || 'Тагийн тоо: ' || p_qty || E'\n'
          || coalesce('Ферм / байгууллага: ' || v_farm || E'\n', '')
          || coalesce('Аймаг, сум: ' || v_place || E'\n', '')
          || coalesce('Тэмдэглэл: ' || v_note || E'\n', '')
          || E'\n' || to_char(now() at time zone 'Asia/Ulaanbaatar', 'YYYY/MM/DD HH24:MI')
          || ' · вэб сайтаас';
    for r in
      select distinct l.chat_id from telegram_links l
      join profiles p on p.id = l.profile_id
      where p.role = 'super_admin' and p.status = 'active'
    loop
      perform tg_send(r.chat_id, v_txt);
      insert into notify_log (chat_id, kind) values (r.chat_id, 'order');
      n := n + 1;
    end loop;
    update order_requests set notified = n where id = v_id;
  exception when others then
    null;
  end;

  -- E-mail to the address shown on the website (v45). A block of its
  -- own: a problem here never touches the saved order or the Telegram.
  begin
    v_to := coalesce(app_secret('order_email'), (select email from site_settings where id = 1));
    perform mail_send(v_to,
      'YAK-TAG: шинэ захиалга №' || v_id || ' — ' || p_qty || ' таг',
      coalesce(v_txt, 'Шинэ захиалга №' || v_id),
      'order', v_id);
  exception when others then
    null;
  end;

  return true;
end $function$;

grant execute on function public.record_public_scan(text, numeric, numeric, numeric, text, uuid, timestamptz, bigint)
  to anon, authenticated;

notify pgrst, 'reload schema';

commit;
