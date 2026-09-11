-- ============================================================
-- YAK-TAG — schema patch v20
-- Security hardening.
--
-- Fixes a real vulnerability introduced in v16, plus abuse limits
-- on the endpoints that anonymous users can reach.
-- ============================================================

-- ============================================================
-- 1. CRITICAL — PRIVATE PHOTOS WERE READABLE ACROSS FARMS
--
-- v16 replaced the per-farm storage policy with
--     using (bucket_id = 'cattle-photos')
-- which lets ANY signed-in user read ANY farm's private photos,
-- including muzzle prints, if they know or guess the path.
--
-- The original per-farm policy was failing for a different reason:
-- my_farm() was written unqualified, and a policy on storage.objects
-- does not resolve it from the public schema. Fully qualifying the
-- call fixes the original rule instead of removing it.
-- ============================================================
drop policy if exists "cattle_photos_read"   on storage.objects;
drop policy if exists "cattle_photos_insert" on storage.objects;
drop policy if exists "cattle photos read"   on storage.objects;
drop policy if exists "cattle photos insert" on storage.objects;

create policy "cattle_photos_read"
on storage.objects for select
to authenticated
using (
  bucket_id = 'cattle-photos'
  and (
    public.is_super()
    or (storage.foldername(name))[1] = 'farm-' || public.my_farm()::text
  )
);

create policy "cattle_photos_insert"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'cattle-photos'
  and (storage.foldername(name))[1] = 'farm-' || public.my_farm()::text
);

-- No update or delete policy on purpose: photo files are write-once.

-- ============================================================
-- 2. PUBLIC BUCKET — SCOPE WRITES BACK TO THE OWN FARM
--
-- v16 allowed any signed-in user to write anywhere in cattle-public.
-- A herder from one farm could overwrite another farm's public photo
-- with anything at all.
-- ============================================================
drop policy if exists "cattle_public_insert" on storage.objects;
drop policy if exists "cattle_public_update" on storage.objects;
drop policy if exists "cattle_public_delete" on storage.objects;

create policy "cattle_public_insert"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'cattle-public'
  and (storage.foldername(name))[1] = 'farm-' || public.my_farm()::text
);

create policy "cattle_public_update"
on storage.objects for update
to authenticated
using (
  bucket_id = 'cattle-public'
  and (storage.foldername(name))[1] = 'farm-' || public.my_farm()::text
);

create policy "cattle_public_delete"
on storage.objects for delete
to authenticated
using (bucket_id = 'cattle-public' and public.is_super());

-- read stays open: it is a public bucket by design
drop policy if exists "cattle_public_read" on storage.objects;
create policy "cattle_public_read"
on storage.objects for select
to public
using (bucket_id = 'cattle-public');

-- ============================================================
-- 3. ANONYMOUS SCAN FLOOD
--
-- record_public_scan is callable by anon with no limit. A script
-- could insert millions of rows, exhaust the free tier, and bury
-- real theft signals in noise.
--
-- Limit: 20 scans per tag per hour. Beyond that the call returns
-- null instead of erroring — a flooder learns nothing from it.
-- ============================================================
create or replace function record_public_scan(
  p_tag_code   text,
  p_lat        numeric default null,
  p_lng        numeric default null,
  p_accuracy   numeric default null,
  p_user_agent text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  c record;
  recent int;
  v_id uuid;
begin
  select id, farm_id, status, reported_lost_at into c
  from cattle where tag_code = p_tag_code;
  if not found then return null; end if;

  select count(*) into recent
  from public_scans
  where cattle_id = c.id and scanned_at > now() - interval '1 hour';

  if recent >= 20 then
    return null;          -- silently ignored, on purpose
  end if;

  insert into public_scans (cattle_id, farm_id, lat, lng, accuracy_m, user_agent, was_lost)
  values (c.id, c.farm_id, p_lat, p_lng, p_accuracy, left(p_user_agent, 200),
          (c.reported_lost_at is not null or c.status in ('lost','stolen')))
  returning id into v_id;

  return v_id;
end $$;

grant execute on function record_public_scan(text, numeric, numeric, numeric, text)
  to anon, authenticated;

-- ============================================================
-- 4. TAG ENUMERATION
--
-- public_tag_lookup answers for any code an anonymous caller sends.
-- Someone can walk YT-000000..YT-999999 and harvest every phone
-- number in the system.
--
-- Full mitigation needs rate limiting at the edge, which Postgres
-- cannot do. What we can do here: log the attempts so a sweep is
-- visible, and stop answering for animals whose farm is archived.
-- ============================================================
create table if not exists lookup_attempts (
  id         bigserial primary key,
  tag_code   text not null,
  found      boolean not null,
  at         timestamptz not null default now()
);
create index if not exists lookup_attempts_at_idx on lookup_attempts(at desc);

alter table lookup_attempts enable row level security;

drop policy if exists lookup_attempts_read on lookup_attempts;
create policy lookup_attempts_read on lookup_attempts for select
  using (is_super());

create or replace function public_tag_lookup(p_tag_code text)
returns table (
  tag_code    text,
  photo_path  text,
  has_phone   boolean,
  phone       text,
  is_lost     boolean
) language plpgsql security definer set search_path = public as $$
declare r record;
begin
  select c.tag_code, c.public_photo_path,
         (c.contact_phone is not null) as has_phone,
         c.contact_phone,
         (c.reported_lost_at is not null or c.status in ('lost','stolen')) as is_lost
    into r
  from cattle c
  join farms f on f.id = c.farm_id
  where c.tag_code = p_tag_code
    and f.status = 'active';

  insert into lookup_attempts (tag_code, found)
  values (left(p_tag_code, 40), found);

  if not found then return; end if;

  tag_code   := r.tag_code;
  photo_path := r.public_photo_path;
  has_phone  := r.has_phone;
  phone      := r.contact_phone;
  is_lost    := r.is_lost;
  return next;
end $$;

grant execute on function public_tag_lookup(text) to anon, authenticated;

-- ============================================================
-- 5. AUDIT LOG MUST NOT BE WRITABLE BY USERS
--
-- Functions write to it as security definer. A user writing
-- directly could forge or bury entries.
-- ============================================================
alter table audit_log enable row level security;

drop policy if exists audit_read on audit_log;
drop policy if exists audit_insert on audit_log;
drop policy if exists audit_no_write on audit_log;

create policy audit_read on audit_log for select
  using (is_super() or (my_role() = 'farm_admin' and farm_id = my_farm()));

-- no insert / update / delete policy at all: only security-definer
-- functions can write, and nobody can alter history.

-- ============================================================
-- 6. LOOK FOR A SWEEP
-- ============================================================
create or replace view lookup_abuse as
select date_trunc('hour', at) as hour,
       count(*)                        as attempts,
       count(*) filter (where not found) as misses,
       count(distinct tag_code)        as distinct_codes
from lookup_attempts
group by 1
having count(*) > 50
order by 1 desc;

alter view lookup_abuse set (security_invoker = on);

-- ============================================================
-- CHECK AFTER RUNNING
--   Log in as admin07 and try to read a Farm 12 photo path —
--   it must fail. Then confirm your own farm's photos still load.
-- ============================================================
