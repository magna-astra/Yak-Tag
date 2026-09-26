-- ============================================================
-- YAK-TAG — schema patch v24
-- Per-caller limit on anonymous tap-page scans.
--
-- THE PROBLEM
-- v20 limits scans to 20 per tag per hour, shared by everyone. One
-- person with a script could use all 20 in seconds, and for the rest
-- of the hour a genuine finder's scan of that animal — possibly a
-- stolen one — was silently thrown away.
--
-- THE FIX
-- Also count per caller. On an anonymous page the caller is the
-- phone's internet address, taken from the request headers the API
-- passes in. It is stored only as a one-way hash, never in the clear.
--
--   same caller, same tag   : 3 per hour
--   same caller, all tags   : 200 per hour  (a herder tapping through
--                             a herd, or a day of offline scans
--                             arriving at once, still fits)
--   per tag, everyone       : 20 per hour, as before — except that a
--                             lost/stolen animal always accepts the
--                             FIRST scan from a caller not yet seen
--                             this hour
--
-- Mobile operators often share one address between many phones, so
-- the per-caller numbers are deliberately loose. Change the three
-- constants below to tune them.
--
-- Safe on the live project and safe to run twice. The function
-- signature is unchanged (same 7 parameters as v23). If the address
-- header is ever missing, caller limits are skipped and behaviour is
-- exactly v23 — nothing is blocked because of it.
-- ============================================================

alter table public_scans add column if not exists caller_hash text;

create index if not exists public_scans_caller_idx
  on public_scans (caller_hash, received_at) where caller_hash is not null;

-- ============================================================
-- WHO IS CALLING
--
-- The API passes the HTTP headers in as a setting. The first
-- address in x-forwarded-for is the phone; the rest are proxies.
-- Hashed with a fixed salt: enough to count repeats, not reversible
-- into an address. Returns null when not called through the API
-- (e.g. from the SQL editor).
-- ============================================================
create or replace function scan_caller_hash()
returns text language plpgsql stable as $$
declare
  h  json;
  ip text;
begin
  h := nullif(current_setting('request.headers', true), '')::json;
  if h is null then return null; end if;
  ip := coalesce(
          nullif(h->>'cf-connecting-ip', ''),
          nullif(trim(split_part(h->>'x-forwarded-for', ',', 1)), ''),
          nullif(h->>'x-real-ip', ''));
  if ip is null then return null; end if;
  return md5('yaktag-scan-v24:' || ip);
exception when others then
  return null;              -- never let this block a scan
end $$;

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
  LIMIT_CALLER_TAG   constant int := 3;
  LIMIT_CALLER_TOTAL constant int := 200;
  LIMIT_TAG          constant int := 20;

  c        record;
  v_id     uuid;
  v_when   timestamptz;
  v_late   boolean;
  v_caller text;
  v_lost   boolean;
  n        int;
begin
  select id, farm_id, status, reported_lost_at into c
  from cattle where tag_code = p_tag_code;
  if not found then return null; end if;
  v_lost := (c.reported_lost_at is not null or c.status in ('lost','stolen'));

  -- A retry of a scan we already have: same answer, and it does not
  -- count against any limit.
  if p_client_uuid is not null then
    select id into v_id from public_scans where client_uuid = p_client_uuid;
    if found then return v_id; end if;
  end if;

  v_caller := scan_caller_hash();

  if v_caller is not null then
    select count(*) into n from public_scans
    where caller_hash = v_caller and received_at > now() - interval '1 hour';
    if n >= LIMIT_CALLER_TOTAL then return null; end if;

    select count(*) into n from public_scans
    where caller_hash = v_caller and cattle_id = c.id
      and received_at > now() - interval '1 hour';
    if n >= LIMIT_CALLER_TAG then return null; end if;
  end if;

  select count(*) into n from public_scans
  where cattle_id = c.id
    and coalesce(received_at, scanned_at) > now() - interval '1 hour';
  if n >= LIMIT_TAG then
    -- Full for this hour. For a lost or stolen animal, a caller we
    -- have not seen on it this hour still gets through: that may be
    -- the one real finder.
    if not (v_lost and v_caller is not null and not exists (
              select 1 from public_scans
              where cattle_id = c.id and caller_hash = v_caller
                and received_at > now() - interval '1 hour')) then
      return null;          -- silently ignored, as in v20
    end if;
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
                            was_lost, scanned_at, received_at, client_uuid,
                            was_offline, caller_hash)
  values (c.id, c.farm_id, p_lat, p_lng, p_accuracy, left(p_user_agent, 200),
          v_lost, v_when, now(), p_client_uuid, v_late, v_caller)
  on conflict (client_uuid) where client_uuid is not null do nothing
  returning id into v_id;

  if v_id is null and p_client_uuid is not null then
    select id into v_id from public_scans where client_uuid = p_client_uuid;
  end if;

  return v_id;
end $$;

grant execute on function
  record_public_scan(text, numeric, numeric, numeric, text, uuid, timestamptz)
  to anon, authenticated;

notify pgrst, 'reload schema';

-- ============================================================
-- CHECK AFTER RUNNING (after a few real taps)
-- ============================================================
-- caller_hash should be filled in for new scans. If it stays empty,
-- the address header is not arriving: nothing breaks, but only the
-- per-tag limit applies (as before v24).
--   select received_at, caller_hash is not null as has_caller
--   from public_scans order by received_at desc limit 10;
--
-- Busiest callers in the last day:
--   select left(caller_hash, 8) as caller, count(*) as scans,
--          count(distinct cattle_id) as animals
--   from public_scans
--   where received_at > now() - interval '1 day' and caller_hash is not null
--   group by 1 order by 2 desc limit 10;
