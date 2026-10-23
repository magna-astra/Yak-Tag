-- ============================================================
-- YAK-TAG — schema v54: a herder corrects a day's milk ONCE
--
-- Was (v8, v46): after the first save a herder could change the
-- number 3 times, then it locked. Now: one correction, then locked.
-- Farm admins and the super admin can still correct a locked entry
-- (policy milk_update, unchanged). The days a herder may enter /
-- correct stay today and yesterday.
--
-- Entries already corrected once or twice are locked by this file:
-- that was their one correction. Also fixes the rule that refused the
-- correction which locks (see the policy below).
--
-- Run in the Tokyo project (mjijgxfmkgtxmpbmshtl). Safe to run twice.
-- The pages (cow.html, the app, the dashboard) say "one correction"
-- from the same push.
-- ============================================================

do $$
begin
  if to_regprocedure('public.count_milk_edit()') is null
     or not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'milk_yield' and column_name = 'locked') then
    raise exception 'Wrong database (the v8 / v46 milk lock is not here): open the Tokyo project mjijgxfmkgtxmpbmshtl and run again.';
  end if;
end $$;

-- Same as v46 (the counter belongs to the server; values a browser
-- sends for edit_count / locked / last_edited_at are ignored), but the
-- first real change locks.
create or replace function public.count_milk_edit()
returns trigger language plpgsql as $$
begin
  new.edit_count     := old.edit_count;
  new.locked         := old.locked;
  new.last_edited_at := old.last_edited_at;
  -- only count real value changes, not no-op updates (a resend of the same number)
  if new.liters is distinct from old.liters then
    new.edit_count     := old.edit_count + 1;
    new.last_edited_at := now();
    new.locked         := true;          -- one correction; after it only an admin changes it
  end if;
  return new;
end $$;

-- The rule for a herder's change looked at "locked" on the row AFTER
-- the change too (a policy without WITH CHECK uses its USING for both).
-- The counter locks that new row, so the change that locks was always
-- refused: under v8 / v46 the 3rd correction failed with an error, and
-- with one correction every correction would. Now "not locked" is
-- asked of the row as it was before; the new row only has to stay the
-- herder's own, recent entry. Unlocking from a browser stays impossible:
-- the counter trigger keeps "locked" from the old row.
alter policy milk_update on public.milk_yield
  with check (
    (select is_super())
    or ((select my_role()) = 'farm_admin' and farm_id = (select my_farm()))
    or ((select my_role()) = 'herder'
        and recorded_by = (select auth.uid())
        and yield_date >= current_date - 1)
  );

-- entries already corrected: lock them (the counter trigger would keep
-- the old "locked", so it is off for this one statement)
alter table public.milk_yield disable trigger milk_edit_counter;
update public.milk_yield set locked = true where edit_count >= 1 and not locked;
alter table public.milk_yield enable trigger milk_edit_counter;
