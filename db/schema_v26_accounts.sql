-- ============================================================
-- YAK-TAG — schema patch v26
-- Accounts: disabling a user must actually take away access.
--
-- BUG: profiles has two on/off columns. The dashboard's
-- "Хаагдсан" switch (admin_update_profile) sets `active`, but every
-- permission check — my_role(), my_farm(), is_super() — looks at
-- `status`. A user switched off in the dashboard kept full access.
--
-- Fix: keep the two in step. Whichever one is changed, the other
-- follows. Existing rows are aligned in the SAFE direction only: if
-- either column says disabled, both become disabled. Nobody is
-- re-enabled by this patch.
--
-- Safe to run twice.
-- ============================================================

-- 1. Align existing rows (disable-only).
update profiles
   set status = 'disabled', active = false
 where (active = false or status = 'disabled')
   and not (active = false and status = 'disabled');

-- 2. Keep them aligned from now on.
create or replace function sync_profile_active()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if new.active = false or new.status = 'disabled' then
      new.active := false; new.status := 'disabled';
    end if;
  elsif new.active is distinct from old.active then
    new.status := case when new.active then 'active' else 'disabled' end;
  elsif new.status is distinct from old.status then
    new.active := (new.status = 'active');
  end if;
  return new;
end $$;

drop trigger if exists profiles_sync_active on profiles;
create trigger profiles_sync_active
  before insert or update of active, status on profiles
  for each row execute function sync_profile_active();

-- ============================================================
-- CHECK AFTER RUNNING — must return no rows:
--   select id, full_name, active, status from profiles
--   where active <> (status = 'active');
-- ============================================================
