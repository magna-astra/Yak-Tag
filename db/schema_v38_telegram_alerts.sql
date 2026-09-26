-- ============================================================
-- YAK-TAG — schema patch v38
-- Telegram alerts (free): when an animal marked lost is tapped,
-- its owner, the farm's admins and the super admin get a Telegram
-- message with the time and a map link of where it was tapped.
--
-- No extra server: the database itself sends the message (pg_net),
-- and Telegram delivers "Start" presses straight to the database
-- (telegram_webhook below). Telegram bots cost nothing.
--
-- Nothing changes until the bot is set up (step 2 below): with no
-- bot token stored, every function here quietly does nothing and the
-- "Telegram" button stays hidden on the pages.
--
-- A failed alert can never block a scan: every call is wrapped so
-- errors are swallowed, and messages are queued (pg_net), so a tap
-- is not slowed down either.
--
-- Safe on the live project and safe to run twice.
--
-- SET UP (once, after running this file):
--   1. In Telegram open @BotFather → /newbot → give it a name and a
--      username ending in "bot" (e.g. YakTagMN_bot). Copy the token.
--   2. Run here, with your own values:
--        select telegram_setup('123456789:AA…your token…', 'YakTagMN_bot');
--   3. About 10 seconds later:
--        select telegram_check();
--      It must say  … "ok":true … "Webhook was set" …
--   (You may delete the saved SQL snippet afterwards — it holds the token.)
-- ============================================================

create extension if not exists pg_net;

-- ============================================================
-- 1. TABLES — none of them readable or writable through the API
-- ============================================================
create table if not exists app_secrets (
  name       text primary key,
  value      text not null,
  updated_at timestamptz not null default now()
);
alter table app_secrets enable row level security;
revoke all on table app_secrets from anon, authenticated;

-- who receives alerts, and in which Telegram chat
create table if not exists telegram_links (
  profile_id uuid primary key references profiles(id) on delete cascade,
  chat_id    bigint not null,
  tg_name    text,
  linked_at  timestamptz not null default now()
);
create index if not exists telegram_links_chat on telegram_links(chat_id);
alter table telegram_links enable row level security;
revoke all on table telegram_links from anon, authenticated;

-- one-time codes behind the "Telegram холбох" link (30 minutes)
create table if not exists telegram_codes (
  code       text primary key,
  profile_id uuid not null references profiles(id) on delete cascade,
  expires_at timestamptz not null
);
alter table telegram_codes enable row level security;
revoke all on table telegram_codes from anon, authenticated;

-- every message sent; also limits alerts to one per animal per chat
-- every 10 minutes
create table if not exists notify_log (
  id         bigserial primary key,
  cattle_id  uuid,
  chat_id    bigint,
  kind       text not null,
  request_id bigint,
  sent_at    timestamptz not null default now()
);
create index if not exists notify_log_recent on notify_log(cattle_id, chat_id, sent_at desc);
alter table notify_log enable row level security;
revoke all on table notify_log from anon, authenticated;

-- ============================================================
-- 2. INTERNAL HELPERS — not callable through the API
-- ============================================================
create or replace function app_secret(p_name text) returns text
language sql stable security definer set search_path = public as $$
  select value from app_secrets where name = p_name
$$;

-- Queue one Telegram message. Returns the pg_net request id, or null
-- when the bot is not set up or anything goes wrong.
create or replace function tg_send(p_chat_id bigint, p_text text)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  v_token text := app_secret('telegram_token');
  v_id    bigint;
begin
  if v_token is null or p_chat_id is null then return null; end if;
  select net.http_post(
    url     := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
    body    := jsonb_build_object('chat_id', p_chat_id, 'text', p_text,
                                  'disable_web_page_preview', true),
    headers := '{"Content-Type": "application/json"}'::jsonb
  ) into v_id;
  return v_id;
exception when others then
  return null;
end $$;

-- The alert itself. p_by = who tapped (null = a stranger on the public page).
create or replace function tg_alert_lost_scan(
  p_cattle_id uuid,
  p_lat       double precision,
  p_lng       double precision,
  p_accuracy  double precision,
  p_when      timestamptz,
  p_by        uuid
) returns int language plpgsql security definer set search_path = public as $$
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
end $$;

revoke all on function app_secret(text) from public, anon, authenticated;
revoke all on function tg_send(bigint, text) from public, anon, authenticated;
revoke all on function tg_alert_lost_scan(uuid, double precision, double precision, double precision, timestamptz, uuid)
  from public, anon, authenticated;

-- ============================================================
-- 3. TRIGGERS — a tap of a lost animal sends the alert
-- ============================================================
-- Stranger on the public tap page (record_public_scan → public_scans).
create or replace function tg_on_public_scan() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.was_lost then
    perform tg_alert_lost_scan(new.cattle_id, new.lat, new.lng, new.accuracy_m, new.scanned_at, null);
  end if;
  return null;
exception when others then
  return null;                        -- the scan is saved no matter what
end $$;

drop trigger if exists public_scan_alert on public_scans;
create trigger public_scan_alert after insert on public_scans
  for each row execute function tg_on_public_scan();

-- A signed-in user (not the owner) opening a lost animal's page.
create or replace function tg_on_app_scan() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from cattle c
             where c.id = new.cattle_id
               and (c.reported_lost_at is not null or c.status in ('lost', 'stolen'))
               and c.owner_id is distinct from new.scanned_by) then
    perform tg_alert_lost_scan(new.cattle_id, new.lat, new.lng, new.accuracy_m, new.scanned_at, new.scanned_by);
  end if;
  return null;
exception when others then
  return null;
end $$;

drop trigger if exists app_scan_alert on scan_events;
create trigger app_scan_alert after insert on scan_events
  for each row execute function tg_on_app_scan();

revoke all on function tg_on_public_scan() from public, anon, authenticated;
revoke all on function tg_on_app_scan() from public, anon, authenticated;

-- ============================================================
-- 4. FOR THE PAGES — signed-in users link / test / unlink
-- ============================================================
create or replace function telegram_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare l record; v_linked boolean;
begin
  if my_role() is null then raise exception 'Not allowed'; end if;
  select * into l from telegram_links where profile_id = auth.uid();
  v_linked := found;
  return jsonb_build_object(
    'configured', app_secret('telegram_token') is not null and app_secret('telegram_bot') is not null,
    'bot',        app_secret('telegram_bot'),
    'linked',     v_linked,
    'tg_name',    case when v_linked then l.tg_name end,
    'linked_at',  case when v_linked then l.linked_at end);
end $$;

create or replace function telegram_link_code() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_bot  text := app_secret('telegram_bot');
  v_code text;
begin
  if my_role() is null then raise exception 'Not allowed'; end if;
  if v_bot is null or app_secret('telegram_token') is null then
    raise exception 'Telegram тохируулаагүй байна.';
  end if;
  delete from telegram_codes where profile_id = auth.uid() or expires_at < now();
  v_code := replace(gen_random_uuid()::text, '-', '');
  insert into telegram_codes (code, profile_id, expires_at)
  values (v_code, auth.uid(), now() + interval '30 minutes');
  return jsonb_build_object('bot', v_bot, 'url', 'https://t.me/' || v_bot || '?start=' || v_code);
end $$;

create or replace function telegram_unlink() returns void
language plpgsql security definer set search_path = public as $$
begin
  if my_role() is null then raise exception 'Not allowed'; end if;
  delete from telegram_links where profile_id = auth.uid();
end $$;

create or replace function telegram_test() returns boolean
language plpgsql security definer set search_path = public as $$
declare v_chat bigint; v_id bigint;
begin
  if my_role() is null then raise exception 'Not allowed'; end if;
  select chat_id into v_chat from telegram_links where profile_id = auth.uid();
  if not found then raise exception 'Telegram холбогдоогүй байна.'; end if;
  if exists (select 1 from notify_log where chat_id = v_chat and kind = 'test'
             and sent_at > now() - interval '1 minute') then
    raise exception 'Нэг минутын дараа дахин оролдоно уу.';
  end if;
  v_id := tg_send(v_chat, '✅ YAK-TAG: туршилтын мэдэгдэл.' || E'\n'
                       || 'Алга болсон гэж мэдэгдсэн мал тань уншуулагдвал энд ингэж мэдэгдэл ирнэ.');
  insert into notify_log (chat_id, kind, request_id) values (v_chat, 'test', v_id);
  return v_id is not null;
end $$;

revoke all on function telegram_status() from public, anon;
revoke all on function telegram_link_code() from public, anon;
revoke all on function telegram_unlink() from public, anon;
revoke all on function telegram_test() from public, anon;
grant execute on function telegram_status() to authenticated;
grant execute on function telegram_link_code() to authenticated;
grant execute on function telegram_unlink() to authenticated;
grant execute on function telegram_test() to authenticated;

-- ============================================================
-- 5. WEBHOOK — Telegram posts "Start" presses here.
-- Callable without login (Telegram cannot log in), but only a request
-- carrying the secret that telegram_setup gave Telegram is accepted.
-- The answer goes back in the same response, so no token is needed.
-- ============================================================
create or replace function telegram_webhook(jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  u      jsonb := $1;
  v_sec  text := app_secret('telegram_webhook_secret');
  v_hdr  text;
  v_chat bigint;
  v_text text;
  v_code text;
  v_pid  uuid;
  v_name text;
  v_farm uuid;
  v_tg   text;
  help   constant text := 'YAK-TAG мэдэгдлийн бот.' || E'\n'
                       || 'Холбохдоо YAK-TAG хуудсан дээрх "Telegram" товчийг дарна уу.' || E'\n'
                       || 'Мэдэгдэл зогсоох: /stop';
begin
  begin
    v_hdr := (current_setting('request.headers', true)::jsonb) ->> 'x-telegram-bot-api-secret-token';
  exception when others then
    v_hdr := null;
  end;
  if v_sec is null or v_hdr is null or v_hdr <> v_sec then
    raise exception 'Not allowed';
  end if;

  begin
    v_chat := (u #>> '{message,chat,id}')::bigint;
    if v_chat is null or coalesce(u #>> '{message,chat,type}', 'private') <> 'private' then
      return '{}'::jsonb;
    end if;
    v_text := trim(coalesce(u #>> '{message,text}', ''));
    v_tg := nullif(trim(coalesce(u #>> '{message,from,first_name}', '') || ' '
                     || coalesce(u #>> '{message,from,last_name}', '')), '');

    if v_text like '/start%' then
      v_code := nullif(split_part(v_text, ' ', 2), '');
      if v_code is null then
        return jsonb_build_object('method', 'sendMessage', 'chat_id', v_chat,
                                  'text', 'Сайн байна уу! ' || help);
      end if;
      delete from telegram_codes where code = v_code and expires_at >= now()
      returning profile_id into v_pid;
      if v_pid is null then
        return jsonb_build_object('method', 'sendMessage', 'chat_id', v_chat,
          'text', 'Холбох код хүчингүй эсвэл хугацаа нь дууссан. YAK-TAG хуудсан дээрх "Telegram" товчийг дахин дарна уу.');
      end if;
      insert into telegram_links (profile_id, chat_id, tg_name) values (v_pid, v_chat, v_tg)
      on conflict (profile_id) do update
        set chat_id = excluded.chat_id, tg_name = excluded.tg_name, linked_at = now();
      select full_name, farm_id into v_name, v_farm from profiles where id = v_pid;
      insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
      values (v_farm, v_pid, 'telegram_link', 'profiles', v_pid, jsonb_build_object('name', v_tg));
      return jsonb_build_object('method', 'sendMessage', 'chat_id', v_chat,
        'text', '✅ ' || coalesce(v_name, '') || ', таны Telegram YAK-TAG-тэй холбогдлоо.' || E'\n'
             || 'Алга болсон гэж мэдэгдсэн мал тань уншуулагдвал энд байршилтай нь мэдэгдэл ирнэ.' || E'\n'
             || 'Зогсоох: /stop');
    end if;

    if v_text = '/stop' then
      delete from telegram_links where chat_id = v_chat;
      return jsonb_build_object('method', 'sendMessage', 'chat_id', v_chat,
        'text', 'Мэдэгдэл зогслоо. Дахин холбох бол YAK-TAG хуудсан дээрх "Telegram" товчийг дарна уу.');
    end if;

    return jsonb_build_object('method', 'sendMessage', 'chat_id', v_chat, 'text', help);
  exception when others then
    return '{}'::jsonb;               -- never make Telegram retry forever
  end;
end $$;

revoke all on function telegram_webhook(jsonb) from public;
grant execute on function telegram_webhook(jsonb) to anon, authenticated;

-- ============================================================
-- 6. SET UP — run by you in this SQL editor (not callable via the API)
-- ============================================================
create or replace function telegram_setup(
  p_token   text,
  p_bot     text,
  p_api_url text default 'https://oxfbxqclqfglpzgzizhq.supabase.co',
  p_api_key text default 'sb_publishable_W3WMWLP28Czb2_5VTDQUlg_--3vfY71'   -- the public key from config.js
) returns text language plpgsql security definer set search_path = public as $$
declare
  v_token  text := trim(coalesce(p_token, ''));
  v_bot    text := ltrim(trim(coalesce(p_bot, '')), '@');
  v_secret text;
  v_id     bigint;
begin
  if v_token !~ '^[0-9]+:[A-Za-z0-9_-]{30,}$' then
    raise exception 'Token буруу байна. BotFather-аас авсан 123456789:AA… хэлбэртэй токен оруулна уу.';
  end if;
  if v_bot !~* '^[a-z0-9_]{2,29}bot$' then
    raise exception 'Bot-ийн username буруу. "bot"-оор төгсөнө, жишээ нь YakTagMN_bot.';
  end if;
  v_secret := coalesce(app_secret('telegram_webhook_secret'),
                       replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''));
  insert into app_secrets (name, value) values
    ('telegram_token', v_token), ('telegram_bot', v_bot), ('telegram_webhook_secret', v_secret)
  on conflict (name) do update set value = excluded.value, updated_at = now();

  select net.http_post(
    url  := 'https://api.telegram.org/bot' || v_token || '/setWebhook',
    body := jsonb_build_object(
      'url', p_api_url || '/rest/v1/rpc/telegram_webhook?apikey=' || p_api_key,
      'secret_token', v_secret,
      'allowed_updates', jsonb_build_array('message'),
      'drop_pending_updates', true)
  ) into v_id;
  insert into app_secrets (name, value) values ('telegram_setup_request', v_id::text)
  on conflict (name) do update set value = excluded.value, updated_at = now();
  return 'Хадгаллаа. 10 секундын дараа ажиллуулна уу:  select telegram_check();';
end $$;

create or replace function telegram_check() returns text
language plpgsql security definer set search_path = public as $$
declare
  v_id bigint := nullif(app_secret('telegram_setup_request'), '')::bigint;
  r    record;
begin
  if v_id is null then return 'telegram_setup(...) хараахан ажиллаагүй байна.'; end if;
  select status_code, content, error_msg into r from net._http_response where id = v_id;
  if not found then return 'Хариу хараахан ирээгүй — хэдэн секундын дараа дахин ажиллуулна уу.'; end if;
  return 'Telegram-ийн хариу (' || coalesce(r.status_code::text, '—') || '): '
         || coalesce(r.content, r.error_msg, '');
end $$;

revoke all on function telegram_setup(text, text, text, text) from public, anon, authenticated;
revoke all on function telegram_check() from public, anon, authenticated;

notify pgrst, 'reload schema';
