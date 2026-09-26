-- ============================================================
-- YAK-TAG — schema patch v37
-- Close the door on older functions for visitors who are not
-- signed in.
--
-- 21 older functions (created before v25) could still be CALLED
-- without logging in. Each refuses inside ("Super admin only",
-- "Not allowed", v34 made those checks null-safe), so nothing could
-- be changed — but they should not be reachable at all.
--
-- What this does, for exactly the functions listed below:
--   revoke execute from PUBLIC and anon   (visitors not signed in)
--   grant  execute to authenticated and service_role
-- so every signed-in user keeps exactly the access they had.
--
-- NOT touched (on purpose):
--   public_tag_lookup, public_tag_state, record_public_scan
--       — the public tap page needs them without login
--   is_super, my_role, my_farm, my_farm_live, gestation_days,
--   predict_calving, scan_caller_hash, fill_expected_dates
--       — helpers used inside security rules and views
--   trigger functions — they run with the table, not by call
--
-- Missing functions are skipped; every version (overload) of a name
-- is handled. Safe on the live project and safe to run twice.
-- ============================================================
do $$
declare
  r record;
  n int := 0;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public'
      and p.proname = any (array[
        'admin_update_cattle', 'admin_update_profile',
        'archive_farm', 'create_farm', 'restore_farm', 'delete_farm',
        'delete_cattle', 'delete_profile', 'delete_tag', 'delete_photo',
        'set_contact_phone', 'unlock_contact_phone', 'set_public_photo', 'unlock_photo',
        'report_lost', 'report_found', 'mark_scan_contacted',
        'record_tag_write', 'recycle_tag', 'retire_tag',
        'milk_on_date'])
  loop
    execute format('revoke all on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated, service_role', r.sig);
    n := n + 1;
  end loop;
  raise notice 'v37: locked % function(s) for anonymous callers', n;
end $$;

-- ============================================================
-- Audit log: only admins read it (the new "Түүх" tab).
-- The very first schema had a policy "audit_scope" letting anyone on
-- the farm (herders too) read it; v20 added the admin-only rule but
-- never removed the old one. Drop it and re-state the admin rule.
-- ============================================================
drop policy if exists audit_scope on audit_log;
drop policy if exists audit_read on audit_log;
create policy audit_read on audit_log for select
  using (coalesce(is_super() or (my_role() = 'farm_admin' and farm_id = my_farm()), false));

notify pgrst, 'reload schema';

-- ============================================================
-- CHECK AFTER RUNNING — both lists as expected:
--   anonymous may call ONLY the three public tap functions (+ helpers):
--     select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--     where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
--     order by 1;
-- ============================================================
