-- ============================================================
-- YAK-TAG — schema patch v15
-- Repair public photo pointers, and check file sizes.
-- ============================================================

-- ---------- 1. WHAT IS ACTUALLY IN THE PUBLIC BUCKET ----------
select '1. FILES IN cattle-public (check the KB column)' as step;
select
  name,
  round(((metadata->>'size')::bigint)/1024.0, 1) as kb,
  created_at
from storage.objects
where bucket_id = 'cattle-public'
order by created_at desc;

-- ---------- 2. SIZE CHECK ON THE PRIVATE BUCKET ----------
-- Resizing happens in the browser at 1200px / 0.75 quality, which
-- should land around 120-250 KB. Anything over ~800 KB means the
-- resize did not run and the raw camera file was uploaded.
select '2. PRIVATE BUCKET SIZES' as step;
select
  round(avg(((metadata->>'size')::bigint)/1024.0), 1) as avg_kb,
  round(min(((metadata->>'size')::bigint)/1024.0), 1) as min_kb,
  round(max(((metadata->>'size')::bigint)/1024.0), 1) as max_kb,
  count(*) as files
from storage.objects
where bucket_id = 'cattle-photos';

-- ---------- 3. BACKFILL THE POINTERS ----------
-- Matches each animal to the newest profile file sitting in the
-- public bucket under its own folder. Fixes photos taken before
-- the pointer write was repaired in v14.
do $$
declare
  rec record;
  found_path text;
  n int := 0;
begin
  for rec in select id, tag_code, farm_id from cattle loop
    select o.name into found_path
    from storage.objects o
    where o.bucket_id = 'cattle-public'
      and o.name like 'farm-' || rec.farm_id::text || '/cow-' || rec.id::text || '/%'
    order by o.created_at desc
    limit 1;

    if found_path is not null then
      update cattle set public_photo_path = found_path where id = rec.id;
      n := n + 1;
      raise notice '% -> %', rec.tag_code, found_path;
    end if;
  end loop;
  raise notice 'Pointers repaired: %', n;
end $$;

-- ---------- 4. RESULT ----------
select '4. POINTERS NOW' as step;
select tag_code, public_photo_path from cattle order by tag_code;

-- ============================================================
-- If block 1 is EMPTY, no file ever reached the public bucket.
-- The photos exist only in the private bucket, so the tap page
-- cannot serve them. Re-take one photo with "Бүтэн бие" selected
-- after deploying the v14 fix — the upload will then run and
-- report any error instead of failing silently.
-- ============================================================
