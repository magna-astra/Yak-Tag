-- ============================================================
-- YAK-TAG — remove old e-mail / test logins (2026-10-23)
--
-- Logins are phone numbers only now. The dashboard's "Устгах" removes a
-- person's PROFILE (or switches it off when it has history) but never the
-- login itself, so old test logins (…@yaktag.test etc.) stay in
-- Authentication → Users. Run in Supabase → SQL Editor:
--   PART 1 first (read only) — see every e-mail login and what it has;
--   PART 2 with the e-mails you want gone typed into the list.
-- A REAL person who logs in with an e-mail is NOT deleted: move him to a
-- phone in the dashboard (Хэрэглэгчид → Засах → "Дээрх утсаар
-- нэвтэрдэг болгох").
-- ============================================================

-- ---------- PART 1: e-mail logins and what is attached (changes nothing) ----------
select u.email,
       p.full_name, p.role, p.status,
       f.code                                                              as farm,
       (select count(*) from public.cattle c where c.owner_id = u.id)        as animals_owned,
       (select count(*) from public.cattle c where c.registered_by = u.id)   as animals_registered,
       (select count(*) from public.audit_log a where a.actor_id = u.id)     as history_rows,
       u.last_sign_in_at::date                                             as last_login
  from auth.users u
  left join public.profiles p on p.id = u.id
  left join public.farms f on f.id = p.farm_id
 where u.email not like '%@yaktag.invalid'
 order by p.role nulls first, u.email;

-- ---------- PART 2: delete the logins you list ----------
-- Type the e-mails between the brackets. For each one:
--   · deleted with its profile and Telegram link, when nothing real is
--     attached (no animals, no records, no history);
--   · NOT deleted when it still has animals / records — the message says
--     so (delete its test farm in the dashboard first, then run again);
--   · NEVER the last active super admin.
-- Safe to run twice (an e-mail already gone says "not found").
do $$
declare
  e text; v_id uuid; v_role text; v_status text;
begin
  foreach e in array array[
    'ganzo@yaktag.test',
    'admin07@yaktag.test'
  ] loop
    select u.id, p.role, p.status into v_id, v_role, v_status
      from auth.users u left join public.profiles p on p.id = u.id
     where lower(u.email) = lower(trim(e));
    if v_id is null then
      raise notice '%: not found', e;
      continue;
    end if;
    if v_role = 'super_admin' and v_status = 'active' and not exists (
         select 1 from public.profiles where role = 'super_admin' and status = 'active' and id <> v_id) then
      raise notice '%: NOT deleted — it is the only active super admin', e;
      continue;
    end if;
    begin
      delete from auth.users where id = v_id;          -- its profile and Telegram link go with it
      raise notice '%: deleted', e;
    exception when foreign_key_violation then
      raise notice '%: NOT deleted — it still has animals or records (delete its test farm first)', e;
    end;
  end loop;
end $$;

-- PART 1 again: what is left
select u.email, p.full_name, p.role, p.status
  from auth.users u left join public.profiles p on p.id = u.id
 where u.email not like '%@yaktag.invalid'
 order by u.email;
