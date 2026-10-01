-- ============================================================
-- YAK-TAG — schema patch v42
-- Stop phone-number harvesting through the public tag lookup.
--
-- public_tag_lookup() is what the tap page (t.html) calls. It returns
-- the owner's phone for the "Эзэмшигч рүү залгах" button. Tag codes are
-- sequential (YT-008000, YT-008001 …) and the lookup had NO per-visitor
-- limit — the 2026-10-01 stress test made 100 lookups in 3 seconds — so a
-- script could have collected every owner's phone in minutes.
--
-- Now: at most 120 lookups per visitor (IP, hashed — the same
-- scan_caller_hash() the scans use since v24) per hour. A real finder
-- needs a handful; even many phones behind one mobile-network address
-- stay far below it. Above the limit the answer is the same as for an
-- unknown tag. Counting uses its own small table, so it keeps working
-- even when the lookup log (lookup_attempts, capped at 500/hour) is full.
--
-- The function's name, parameters and returned columns are unchanged,
-- so t.html needs no change.
--
-- Also removes the test rows the stress / security tests left in the
-- lookup log (codes starting with ZZ-; real tags start with YT-).
--
-- Safe on the live project and safe to run twice.
-- ============================================================

do $$
begin
  if to_regprocedure('public.scan_caller_hash()') is null or to_regclass('public.lookup_attempts') is null then
    raise exception 'Wrong database: this is not the YAK-TAG project (oxfbxqclqfglpzgzizhq). Open the right project and run again.';
  end if;
end $$;

create table if not exists public.lookup_rate (
  caller_hash text        not null,
  hour        timestamptz not null,
  n           integer     not null default 0,
  primary key (caller_hash, hour)
);
alter table public.lookup_rate enable row level security;
revoke all on table public.lookup_rate from anon, authenticated;

create or replace function public.public_tag_lookup(p_tag_code text)
returns table (
  tag_code    text,
  photo_path  text,
  has_phone   boolean,
  phone       text,
  is_lost     boolean
) language plpgsql security definer set search_path = public as $$
declare
  LIMIT_PER_HOUR constant int := 120;
  r        record;
  v_found  boolean;
  v_recent int;
  v_caller text;
  v_n      int;
begin
  -- per-visitor limit first: over it, answer exactly like an unknown tag
  v_caller := scan_caller_hash();
  if v_caller is not null then
    insert into lookup_rate as lr (caller_hash, hour, n)
    values (v_caller, date_trunc('hour', now()), 1)
    on conflict (caller_hash, hour) do update set n = lr.n + 1
    returning lr.n into v_n;
    if random() < 0.01 then
      delete from lookup_rate where hour < now() - interval '2 days';
    end if;
    if v_n > LIMIT_PER_HOUR then
      return;
    end if;
  end if;

  select c.tag_code, c.public_photo_path,
         (c.contact_phone is not null) as has_phone,
         c.contact_phone,
         (c.reported_lost_at is not null or c.status in ('lost','stolen')) as is_lost
    into r
  from cattle c
  join farms f on f.id = c.farm_id
  where c.tag_code = p_tag_code
    and f.status = 'active';
  v_found := found;                 -- capture before any other statement

  select count(*) into v_recent
  from lookup_attempts
  where at > now() - interval '1 hour';

  if v_recent < 500 then
    insert into lookup_attempts (tag_code, found)
    values (left(p_tag_code, 40), v_found);
  end if;

  -- Roughly 1 lookup in 100 clears out old rows. No pg_cron needed.
  if random() < 0.01 then
    delete from lookup_attempts where at < now() - interval '30 days';
  end if;

  if not v_found then return; end if;

  tag_code   := r.tag_code;
  photo_path := r.public_photo_path;
  has_phone  := r.has_phone;
  phone      := r.contact_phone;
  is_lost    := r.is_lost;
  return next;
end $$;

grant execute on function public.public_tag_lookup(text) to anon, authenticated;

-- test rows from the 2026-10-01 stress / security tests
delete from public.lookup_attempts where tag_code like 'ZZ-%';

notify pgrst, 'reload schema';
