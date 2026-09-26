-- ============================================================
-- YAK-TAG — schema patch v23
-- Offline scans for the public tap page.
--
-- A scan made with no signal is kept on the phone and sent later.
-- For that the server must (a) accept the time the scan really
-- happened, and (b) recognise a scan it already has, because a
-- phone may retry after a dropped connection.
--
-- Safe on the live project and safe to run twice:
--   - two new nullable columns, no rewrite of existing rows
--   - record_public_scan keeps every existing parameter, so the
--     current t.html keeps working before and after this runs
--   - rate limit unchanged (20 per tag per hour)
--
-- scan_events (owner app) needs nothing: it already has
-- client_uuid (unique), phone-clock scanned_at and was_offline.
-- ============================================================

-- ============================================================
-- 1. COLUMNS
--
-- received_at is added WITHOUT a default first, so existing rows
-- stay null. A default in the same step would stamp every old
-- scan with "now" — and the rate limit below would then count
-- them all as this hour's scans and block real ones for an hour.
-- ============================================================
alter table public_scans add column if not exists client_uuid uuid;
alter table public_scans add column if not exists received_at timestamptz;
alter table public_scans add column if not exists was_offline boolean not null default false;
alter table public_scans alter column received_at set default now();

create unique index if not exists public_scans_client_uuid_idx
  on public_scans (client_uuid) where client_uuid is not null;
create index if not exists public_scans_cattle_received_idx
  on public_scans (cattle_id, received_at);

-- ============================================================
-- 2. RECORD_PUBLIC_SCAN WITH OFFLINE FIELDS
--
-- Replaces the v20 version. Dropped first because adding
-- parameters would otherwise create a second overload, and the
-- API could not tell the two apart.
--
-- p_scanned_at is the phone's clock. Accepted only within the
-- last 7 days (and up to 5 minutes ahead for clock drift);
-- otherwise the server time is used. A backdated scan can never
-- replace a newer position, because "last seen" is the latest
-- scanned_at.
--
-- The rate limit counts by arrival time (received_at), not by
-- scanned_at — otherwise backdating would bypass it.
-- ============================================================
drop function if exists record_public_scan(text, numeric, numeric, numeric, text);

create or replace function record_public_scan(
  p_tag_code    text,
  p_lat         numeric default null,
  p_lng         numeric default null,
  p_accuracy    numeric default null,
  p_user_agent  text default null,
  p_client_uuid uuid default null,
  p_scanned_at  timestamptz default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  c        record;
  recent   int;
  v_id     uuid;
  v_when   timestamptz;
  v_late   boolean;
begin
  select id, farm_id, status, reported_lost_at into c
  from cattle where tag_code = p_tag_code;
  if not found then return null; end if;

  -- Already have this exact scan (phone retried): same answer again.
  if p_client_uuid is not null then
    select id into v_id from public_scans where client_uuid = p_client_uuid;
    if found then return v_id; end if;
  end if;

  select count(*) into recent
  from public_scans
  where cattle_id = c.id
    and coalesce(received_at, scanned_at) > now() - interval '1 hour';

  if recent >= 20 then
    return null;          -- silently ignored, on purpose (as v20)
  end if;

  if p_scanned_at is not null
     and p_scanned_at between now() - interval '7 days'
                          and now() + interval '5 minutes' then
    v_when := least(p_scanned_at, now());
  else
    v_when := now();
  end if;
  v_late := v_when < now() - interval '2 minutes';

  insert into public_scans (cattle_id, farm_id, lat, lng, accuracy_m, user_agent,
                            was_lost, scanned_at, received_at, client_uuid, was_offline)
  values (c.id, c.farm_id, p_lat, p_lng, p_accuracy, left(p_user_agent, 200),
          (c.reported_lost_at is not null or c.status in ('lost','stolen')),
          v_when, now(), p_client_uuid, v_late)
  on conflict (client_uuid) where client_uuid is not null do nothing
  returning id into v_id;

  -- Lost a race with a parallel retry of the same scan.
  if v_id is null and p_client_uuid is not null then
    select id into v_id from public_scans where client_uuid = p_client_uuid;
  end if;

  return v_id;
end $$;

grant execute on function
  record_public_scan(text, numeric, numeric, numeric, text, uuid, timestamptz)
  to anon, authenticated;

-- Make the API pick up the new signature right away. The SQL editor
-- runs this whole file as one transaction, so there is no moment
-- where the function is missing.
notify pgrst, 'reload schema';

-- ============================================================
-- CHECK AFTER RUNNING
-- ============================================================
-- Exactly one record_public_scan, with 7 arguments:
--   select pg_get_function_identity_arguments(oid)
--   from pg_proc where proname = 'record_public_scan';
--
-- Offline scans once phones start sending them:
--   select scanned_at, received_at, was_offline from public_scans
--   where was_offline order by received_at desc limit 20;
