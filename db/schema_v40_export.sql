-- ============================================================
-- YAK-TAG — schema patch v40
-- Excel report: milk added up per animal per month.
--
-- The dashboard builds the Excel file itself (no paid service). Daily
-- milk rows can run into the millions, so they are added up here and
-- only the monthly totals are downloaded.
--
-- Runs with the caller's own rights (security invoker): the normal
-- read rules on milk_yield decide what each admin gets — their own
-- farm, or everything for the super admin.
--
-- Safe on the live project and safe to run twice.
-- ============================================================

create or replace function export_milk_monthly(
  p_from    date,
  p_to      date,
  p_farm_id uuid default null
) returns table (cattle_id uuid, month date, days integer, liters numeric)
language sql stable security invoker set search_path = public as $$
  select m.cattle_id,
         date_trunc('month', m.yield_date)::date,
         count(*)::integer,
         round(sum(m.liters)::numeric, 1)
  from milk_yield m
  where m.yield_date between p_from and p_to
    and (p_farm_id is null or m.farm_id = p_farm_id)
  group by 1, 2
  order by 1, 2
$$;

revoke all on function export_milk_monthly(date, date, uuid) from public, anon;
grant execute on function export_milk_monthly(date, date, uuid) to authenticated;

notify pgrst, 'reload schema';
