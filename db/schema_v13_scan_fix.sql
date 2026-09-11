-- ============================================================
-- YAK-TAG — schema patch v13
--
-- BUG: the public tap page records to public_scans, but the
-- dashboard reads last position from scan_events. So tapping a
-- tag logged the scan correctly and then showed nothing anywhere.
--
-- Fix: the dashboard takes the most recent position from EITHER
-- source. A tap is a tap, whoever made it.
-- ============================================================

-- ============================================================
-- 1. ONE PLACE TO ASK "WHERE WAS THIS ANIMAL LAST SEEN"
-- ============================================================
create or replace view all_scans as
select
  cattle_id, farm_id, scanned_at, lat, lng, accuracy_m,
  'app'::text as source,
  scanned_by  as actor
from scan_events
union all
select
  cattle_id, farm_id, scanned_at, lat, lng, accuracy_m,
  'public'::text as source,
  null::uuid as actor
from public_scans;

alter view all_scans set (security_invoker = on);

-- ============================================================
-- 2. REBUILD THE DASHBOARD VIEW AGAINST BOTH SOURCES
-- ============================================================
drop view if exists cattle_dashboard;

create view cattle_dashboard as
select
  c.id, c.farm_id, c.tag_code, c.sex, c.birth_year, c.breed,
  c.weight_kg, c.status, c.owner_id,
  c.reported_lost_at,
  c.contact_phone, c.contact_locked_at, c.public_photo_path,
  p.full_name  as owner_name,
  f.name       as farm_name,
  f.code       as farm_code,
  f.center_lat as farm_lat,
  f.center_lng as farm_lng,

  s.scanned_at as last_seen_at,
  s.lat        as last_lat,
  s.lng        as last_lng,
  s.source     as last_scan_source,

  today_milk.liters      as milk_today,
  today_milk.edit_count  as milk_edits,
  today_milk.locked      as milk_locked,
  today_milk.id          as milk_id,
  month_milk.total       as milk_this_month,
  last_feed.occurred_at  as last_fed_at,
  vac.given_on           as last_vaccination,
  vac.due_next           as next_vaccination_due,
  vac.vaccine_name       as vaccine_name,

  (select count(*) from public_scans ps
     where ps.cattle_id = c.id and ps.scanned_at > now() - interval '30 days')
                         as public_scans_30d,
  (select count(*) from all_scans a where a.cattle_id = c.id) as total_scans

from cattle c
join profiles p on p.id = c.owner_id
join farms f    on f.id = c.farm_id

-- most recent position from either table, ignoring scans with no GPS
left join lateral (
  select * from all_scans a
  where a.cattle_id = c.id and a.lat is not null
  order by a.scanned_at desc limit 1) s on true

left join lateral (
  select id, liters, edit_count, locked from milk_yield m
  where m.cattle_id = c.id and m.yield_date = current_date) today_milk on true

left join lateral (
  select sum(liters) as total from milk_yield m
  where m.cattle_id = c.id
    and date_trunc('month', m.yield_date) = date_trunc('month', current_date)
) month_milk on true

left join lateral (
  select occurred_at from health_events h
  where h.cattle_id = c.id and h.kind = 'feeding'
  order by occurred_at desc limit 1) last_feed on true

left join lateral (
  select given_on, due_next, vaccine_name from health_events h
  where h.cattle_id = c.id and h.kind = 'vaccination'
  order by coalesce(given_on, occurred_at::date) desc limit 1) vac on true;

alter view cattle_dashboard set (security_invoker = on);

-- ============================================================
-- 3. LET OWNERS READ THEIR OWN PUBLIC SCANS
--    (the policy existed, but re-stating it here keeps v13
--     self-sufficient if v7 was only partly applied)
-- ============================================================
drop policy if exists public_scan_read on public_scans;
create policy public_scan_read on public_scans for select
  using (
    is_super()
    or (my_role() = 'farm_admin' and farm_id = my_farm())
    or (my_role() = 'herder' and exists (
          select 1 from cattle c
          where c.id = public_scans.cattle_id and c.owner_id = auth.uid()))
  );

-- ============================================================
-- DIAGNOSE — run these if a tap still shows nothing
-- ============================================================
-- Did the tap reach the database at all?
--   select * from public_scans order by scanned_at desc limit 10;
--
-- Did it carry a position? lat null means the browser denied location.
--   select tag_code, ps.scanned_at, ps.lat, ps.lng
--     from public_scans ps join cattle c on c.id = ps.cattle_id
--    order by ps.scanned_at desc limit 10;
--
-- What does the dashboard now think?
--   select tag_code, last_seen_at, last_lat, last_lng, last_scan_source, total_scans
--     from cattle_dashboard order by tag_code;
-- ============================================================
