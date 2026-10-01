-- ============================================================
-- YAK-TAG — schema patch v43
-- Website contact details (phone, e-mail, address) editable by the
-- super admin from the dashboard ("Холбоо барих"), any time.
--
--   site_settings            one row (id = 1); anyone may READ it — it is
--                            printed on the public website anyway
--   update_site_contacts()   the only way to change it: super admin only
--                            (null-safe check), every field checked, every
--                            change written to the audit log ("Түүх")
--   submit_order()           same as v41, but its two "please call"
--                            messages now show the current phone
--
-- The website reads the row with a small script (assets/contacts.js);
-- the numbers written in the pages stay as the fallback.
--
-- Needs v41. Safe on the live project and safe to run twice.
-- ============================================================

do $$
begin
  if to_regprocedure('public.is_super()') is null or to_regclass('public.order_requests') is null then
    raise exception 'Wrong database (or v41 not run): open the YAK-TAG project oxfbxqclqfglpzgzizhq and run again.';
  end if;
end $$;

create table if not exists public.site_settings (
  id          integer primary key default 1 check (id = 1),
  phone       text not null,
  email       text not null,
  address     text,
  updated_at  timestamptz not null default now(),
  updated_by  uuid references public.profiles(id)
);
insert into public.site_settings (id, phone, email, address)
values (1, '9903 1147', 'magna.astra.mn@gmail.com', null)
on conflict (id) do nothing;

alter table public.site_settings enable row level security;
revoke all on table public.site_settings from anon, authenticated;
grant select on table public.site_settings to anon, authenticated;
drop policy if exists site_settings_read on public.site_settings;
create policy site_settings_read on public.site_settings for select using (true);

create or replace function public.update_site_contacts(
  p_phone   text,
  p_email   text,
  p_address text default null
) returns void language plpgsql security definer set search_path = public as $$
declare
  v_phone text := trim(coalesce(p_phone, ''));
  v_email text := lower(trim(coalesce(p_email, '')));
  v_addr  text := nullif(left(trim(coalesce(p_address, '')), 200), '');
  old     record;
begin
  if not coalesce(is_super(), false) then
    raise exception 'Зөвхөн ерөнхий админ өөрчилнө.';
  end if;
  if v_phone !~ '^\+?[0-9][0-9 ()-]{6,19}$' or length(regexp_replace(v_phone, '[^0-9]', '', 'g')) < 8 then
    raise exception 'Утасны дугаар буруу (жишээ нь 9903 1147).';
  end if;
  if length(v_email) > 120 or v_email !~ '^[^@\s<>"'']+@[^@\s<>"'']+\.[a-z]{2,}$' then
    raise exception 'И-мэйл хаяг буруу.';
  end if;
  if v_addr ~ '[<>]' then
    raise exception 'Хаягт < > тэмдэгт оруулах боломжгүй.';
  end if;

  select phone, email, address into old from site_settings where id = 1;
  update site_settings
     set phone = v_phone, email = v_email, address = v_addr, updated_at = now(), updated_by = auth.uid()
   where id = 1;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (null, auth.uid(), 'site_contacts', 'site_settings', null,
          jsonb_build_object('phone', v_phone, 'email', v_email, 'address', v_addr,
                             'old_phone', old.phone, 'old_email', old.email, 'old_address', old.address));
end $$;

revoke all on function public.update_site_contacts(text, text, text) from public, anon;
grant execute on function public.update_site_contacts(text, text, text) to authenticated;

-- submit_order: identical to v41 except the phone in its two messages
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

  return true;
end $$;

revoke all on function public.submit_order(text, text, integer, text, text, text, text) from public;
grant execute on function public.submit_order(text, text, integer, text, text, text, text) to anon, authenticated;

notify pgrst, 'reload schema';
