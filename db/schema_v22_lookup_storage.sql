-- ============================================================
-- YAK-TAG — schema patch v22
-- Public lookup fixes, public bucket listing, milk index.
--
-- Safe to run on the live project and safe to run twice.
-- Function signatures are unchanged, so t.html keeps working
-- throughout. Nothing here touches the map or scan data.
-- ============================================================

-- ============================================================
-- 1. UNKNOWN TAGS RETURNED AN EMPTY ANIMAL
--
-- The INSERT into lookup_attempts sets FOUND to true, so the
-- "if not found then return" after it never fired. An unknown or
-- archived tag came back as one row of nulls and the tap page
-- showed a blank animal instead of "Бүртгэл олдсонгүй".
-- Fix: remember the lookup result before logging.
--
-- 2. LOOKUP LOG COULD FILL THE DATABASE
--
-- Every anonymous lookup wrote a row with no limit. A script
-- could fill the 500 MB free tier in days and stop the system.
-- Now bounded two ways:
--   - at most 500 logged lookups per hour (answers still work;
--     500/hour is still far above the lookup_abuse threshold
--     of 50, so a sweep remains visible)
--   - rows older than 30 days are pruned as lookups come in
-- Worst case ≈ 360,000 rows (~35 MB), instead of unlimited.
-- ============================================================
create or replace function public_tag_lookup(p_tag_code text)
returns table (
  tag_code    text,
  photo_path  text,
  has_phone   boolean,
  phone       text,
  is_lost     boolean
) language plpgsql security definer set search_path = public as $$
declare
  r        record;
  v_found  boolean;
  v_recent int;
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

grant execute on function public_tag_lookup(text) to anon, authenticated;

-- Test rows left by the 2026-09-26 live check.
delete from lookup_attempts where tag_code = 'ZZ-STRESS-TEST';

-- ============================================================
-- 3. PUBLIC BUCKET COULD BE LISTED BY ANYONE
--
-- The read policy on cattle-public allowed anonymous SELECT, so
-- anyone could list every farm id, animal id and photo filename.
--
-- Viewing a photo does NOT need this policy: files in a public
-- bucket are served from /object/public/... without checking
-- policies. That is how t.html shows the photo. Only listing and
-- the owner's own upload (upsert) use SELECT — so SELECT is kept
-- for signed-in users on their own farm, and for super admin.
-- ============================================================
drop policy if exists "cattle_public_read" on storage.objects;

create policy "cattle_public_read"
on storage.objects for select
to authenticated
using (
  bucket_id = 'cattle-public'
  and (
    public.is_super()
    or (storage.foldername(name))[1] = 'farm-' || public.my_farm()::text
  )
);

-- ============================================================
-- 4. MILK BY DATE
--
-- The dashboard asks for every milk row on one date. The existing
-- unique index starts with cattle_id, so that query scans the
-- whole table — fine today, slow at ~4M rows a year.
-- Leading with yield_date serves both super admin (date only)
-- and farm admin (date + farm, added by row security).
-- ============================================================
create index if not exists milk_yield_date_farm_idx
  on milk_yield (yield_date, farm_id);

-- ============================================================
-- CHECK AFTER RUNNING
-- ============================================================
-- Unknown tag must return NO rows (was one row of nulls):
--   select * from public_tag_lookup('ZZ-NOT-A-TAG');
--   delete from lookup_attempts where tag_code = 'ZZ-NOT-A-TAG';
--
-- Policies on the public bucket — cattle_public_read should now
-- say {authenticated}:
--   select policyname, roles, cmd from pg_policies
--   where tablename = 'objects' and policyname like 'cattle_public%';
