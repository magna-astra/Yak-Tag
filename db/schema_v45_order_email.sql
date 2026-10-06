-- ============================================================
-- YAK-TAG — schema patch v45
-- Website orders also arrive by E-MAIL. Telegram stays exactly as it is.
--
--   mail_send()     internal: sends one e-mail through Resend (free plan:
--                   3 000 a month, 100 a day). Not callable through the
--                   API. Stops at 90 a day, so a spammer cannot use up
--                   the free quota (Telegram keeps working regardless).
--   email_log       every e-mail sent (no API access)
--   email_setup()   run ONCE in the SQL Editor with the Resend API key:
--                     select public.email_setup('re_…');
--                   it sends a test e-mail at once
--   email_check()   in the SQL Editor, if an e-mail does not arrive:
--                     select * from public.email_check();
--   submit_order()  same as v43 + one e-mail to the address shown on the
--                   website (dashboard → "Холбоо барих")
--
-- Until email_setup() is run nothing changes: orders go to Telegram
-- exactly as before. The last statement shows the latest 5 orders and
-- whether their Telegram message went out.
--
-- Needs v38, v41, v43. Safe on the live project and safe to run twice.
-- ============================================================

do $$
begin
  if to_regprocedure('public.is_super()') is null
     or to_regprocedure('public.tg_send(bigint,text)') is null
     or to_regclass('public.order_requests') is null
     or to_regclass('public.site_settings') is null then
    raise exception 'Wrong database (or v38 / v41 / v43 not run): open the YAK-TAG project oxfbxqclqfglpzgzizhq and run again.';
  end if;
end $$;

create table if not exists public.email_log (
  id         bigserial primary key,
  kind       text not null,               -- order | test
  to_addr    text not null,
  ref_id     bigint,                      -- order number
  request_id bigint,                      -- pg_net request (answer in net._http_response)
  sent_at    timestamptz not null default now()
);
alter table public.email_log enable row level security;
revoke all on table public.email_log from anon, authenticated;

-- One e-mail through Resend. Returns the pg_net request id, or null when
-- e-mail is not set up, the address is not valid, the daily cap is
-- reached, or anything goes wrong.
create or replace function public.mail_send(
  p_to      text,
  p_subject text,
  p_text    text,
  p_kind    text   default 'mail',
  p_ref     bigint default null
) returns bigint language plpgsql security definer set search_path = public as $$
declare
  v_key  text := app_secret('resend_key');
  v_from text := coalesce(app_secret('mail_from'), 'YAK-TAG <noreply@yaktag.org>');
  v_to   text := lower(trim(coalesce(p_to, '')));
  v_id   bigint;
begin
  if v_key is null or v_to !~ '^[^@\s<>"'']+@[^@\s<>"'']+\.[a-z]{2,}$' then return null; end if;
  if (select count(*) from email_log where sent_at > now() - interval '1 day') >= 90 then
    return null;
  end if;
  select net.http_post(
    url     := 'https://api.resend.com/emails',
    body    := jsonb_build_object(
                 'from',    v_from,
                 'to',      jsonb_build_array(v_to),
                 'subject', left(coalesce(p_subject, 'YAK-TAG'), 200),
                 'text',    coalesce(p_text, '')),
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'Authorization', 'Bearer ' || v_key)
  ) into v_id;
  insert into email_log (kind, to_addr, ref_id, request_id)
  values (coalesce(p_kind, 'mail'), v_to, p_ref, v_id);
  return v_id;
exception when others then
  return null;
end $$;
revoke all on function public.mail_send(text, text, text, text, bigint) from public, anon, authenticated;

-- Run once in the SQL Editor:  select public.email_setup('re_…');
-- Optional 2nd argument: send orders to another address than the one
-- shown on the website.
create or replace function public.email_setup(p_key text, p_to text default null)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_key text := trim(coalesce(p_key, ''));
  v_to  text;
  v_id  bigint;
begin
  if v_key !~ '^re_[A-Za-z0-9_-]{20,}$' then
    raise exception 'API key буруу байна. Resend → API Keys хэсгээс авсан re_… хэлбэртэй түлхүүрийг бүтнээр нь оруулна уу.';
  end if;
  insert into app_secrets (name, value) values ('resend_key', v_key)
  on conflict (name) do update set value = excluded.value, updated_at = now();
  if nullif(trim(p_to), '') is not null then
    insert into app_secrets (name, value) values ('order_email', lower(trim(p_to)))
    on conflict (name) do update set value = excluded.value, updated_at = now();
  end if;

  v_to := coalesce(app_secret('order_email'), (select email from site_settings where id = 1));
  v_id := mail_send(v_to, 'YAK-TAG: туршилтын и-мэйл',
            'Сайн байна уу,' || E'\n\n'
            || 'Энэ бол YAK-TAG системийн туршилтын и-мэйл. Вэб сайтаас ирэх захиалга '
            || 'одоо Telegram-аас гадна энэ хаягт бас ирнэ.' || E'\n\n' || 'https://yaktag.org',
            'test', null);
  if v_id is null then
    return 'Түлхүүр хадгалагдлаа, гэхдээ туршилтын и-мэйл илгээгдсэнгүй (хаяг: '
           || coalesce(v_to, '—') || '). Вэб сайтын и-мэйл хаягийг шалгана уу.';
  end if;
  return 'OK — туршилтын и-мэйл ' || v_to || ' хаяг руу илгээгдлээ. 1 минутын дараа Inbox, '
         || 'эсвэл Spam хавтсаа шалгана уу. Ирээгүй бол: select * from public.email_check();';
end $$;
revoke all on function public.email_setup(text, text) from public, anon, authenticated;

-- What Resend answered to the last 10 e-mails (200 = sent).
create or replace function public.email_check()
returns table (sent_at text, kind text, to_addr text, http_status integer, answer text)
language sql security definer set search_path = public as $$
  select to_char(l.sent_at at time zone 'Asia/Ulaanbaatar', 'MM/DD HH24:MI'),
         l.kind, l.to_addr, r.status_code,
         left(coalesce(r.content::text, r.error_msg,
                       case when l.request_id is null then 'илгээгдээгүй' else 'хариу хүлээж байна' end), 300)
  from email_log l
  left join net._http_response r on r.id = l.request_id
  order by l.id desc
  limit 10
$$;
revoke all on function public.email_check() from public, anon, authenticated;

-- submit_order: identical to v43 + the e-mail block at the end
create or replace function public.submit_order(
  p_name    text,
  p_phone   text,
  p_qty     integer,
  p_farm    text default null,
  p_place   text default null,
  p_note    text default null,
  p_website text default null      -- hidden field; must stay empty
) returns boolean language plpgsql security definer set search_path = public as $$
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
  if (select count(*) from order_requests where created_at > now() - interval '1 hour') >= 30 then
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
end $$;

revoke all on function public.submit_order(text, text, integer, text, text, text, text) from public;
grant execute on function public.submit_order(text, text, integer, text, text, text, text) to anon, authenticated;

notify pgrst, 'reload schema';

-- The latest 5 website orders: telegram_chats = how many linked super
-- admins were sent the order (0 = nobody has linked Telegram).
select o.id                                                          as "№",
       to_char(o.created_at at time zone 'Asia/Ulaanbaatar', 'MM/DD HH24:MI') as "цаг",
       o.qty                                                         as "таг",
       o.notified                                                    as telegram_chats,
       (select count(*) from public.telegram_links l
          join public.profiles p on p.id = l.profile_id
         where p.role = 'super_admin' and p.status = 'active')       as linked_super_admins,
       public.app_secret('resend_key') is not null                   as email_ready
from public.order_requests o
order by o.id desc
limit 5;
