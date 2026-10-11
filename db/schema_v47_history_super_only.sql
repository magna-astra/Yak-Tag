-- ============================================================
-- YAK-TAG — schema patch v47
-- The "Түүх" history (audit log) is for the SUPER ADMIN only.
--
-- Until now a farm admin could read the history of their own farm
-- (v37). The owner wants it for the super admin only; farm admins see
-- their own tags in the "Тагууд" tab instead (read-only).
-- The dashboard hides the tab; this rule makes sure the database
-- refuses it too, whatever page asks.
--
-- Safe on the live project and safe to run twice.
-- ============================================================

do $$
begin
  if to_regprocedure('public.is_super()') is null or to_regclass('public.audit_log') is null then
    raise exception 'Wrong database: open the YAK-TAG project oxfbxqclqfglpzgzizhq and run again.';
  end if;
end $$;

drop policy if exists audit_read on public.audit_log;
create policy audit_read on public.audit_log for select
  using (coalesce(public.is_super(), false));

notify pgrst, 'reload schema';

-- CHECK: one row, rule = super admin only
select policyname, cmd, qual from pg_policies
 where schemaname = 'public' and tablename = 'audit_log';
