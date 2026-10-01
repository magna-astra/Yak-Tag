-- ============================================================
-- YAK-TAG — schema patch v41
-- Website order form → Telegram (free).
--
-- The order page used to open the visitor's e-mail app, which many
-- phones do not have. Now the form sends the order here:
--   * it is saved in order_requests (nothing is lost if Telegram is
--     down), and
--   * every super admin who linked Telegram (v38) gets it at once.
--
-- submit_order() can be called without logging in (website visitors).
-- Protection against spam:
--   * a hidden "website" field that people never fill — bots do; such
--     requests are quietly dropped
--   * at most 3 orders per visitor per hour, 30 in total per hour
--   * every field checked and length-limited
-- Nobody can read the orders through the API except the super admin.
--
-- Needs v38 (Telegram) for the message; without a linked Telegram the
-- order is still saved.
--
-- Safe on the live project and safe to run twice.
-- ============================================================

-- Stop at once if this is not the YAK-TAG database (wrong project open).
do $$
begin
  if to_regprocedure('public.is_super()') is null or to_regclass('public.cattle') is null
     or to_regprocedure('public.tg_send(bigint,text)') is null then
    raise exception 'Wrong database: this is not the YAK-TAG project (oxfbxqclqfglpzgzizhq), or v38 (Telegram) has not been run here. Open the right project and run again.';
  end if;
end $$;

create table if not exists public.order_requests (
  id          bigserial primary key,
  created_at  timestamptz not null default now(),
  name        text not null,
  phone       text not null,
  qty         integer not null,
  farm        text,
  place       text,          -- aimag, soum
  note        text,
  caller_hash text,
  status      text not null default 'new' check (status in ('new', 'contacted', 'done', 'spam')),
  notified    integer not null default 0     -- how many Telegram chats were sent the order
);
create index if not exists order_requests_recent on public.order_requests(created_at desc);
alter table public.order_requests enable row level security;
revoke all on table public.order_requests from anon, authenticated;
drop policy if exists order_requests_read on public.order_requests;
create policy order_requests_read on public.order_requests for select
  using (coalesce(public.is_super(), false));
grant select on table public.order_requests to authenticated;     -- the policy limits it to the super admin

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
    raise exception 'Та саяхан захиалга илгээсэн байна. Яаралтай бол 9903 1147 руу залгана уу.';
  end if;
  if (select count(*) from order_requests where created_at > now() - interval '1 hour') >= 30 then
    raise exception 'Одоогоор хүсэлт их байна. 9903 1147 руу залгана уу.';
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

  return true;
end $$;

revoke all on function public.submit_order(text, text, integer, text, text, text, text) from public;
grant execute on function public.submit_order(text, text, integer, text, text, text, text) to anon, authenticated;

notify pgrst, 'reload schema';

-- ============================================================
-- See the orders (SQL Editor):
--   select id, created_at, name, phone, qty, farm, place, note, notified
--   from order_requests order by id desc limit 20;
-- ============================================================
