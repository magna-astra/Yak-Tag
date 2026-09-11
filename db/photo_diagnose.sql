-- ============================================================
-- YAK-TAG — why is the photo not showing?
-- Run each block, note which one is wrong.
-- ============================================================

-- 1. Does the public bucket exist, and is it actually public?
--    cattle-public MUST show public = true.
--    cattle-photos MUST show public = false.
select '1. BUCKETS' as step;
select id, name, public from storage.buckets order by name;

-- 2. Did any file reach the public bucket?
select '2. FILES IN PUBLIC BUCKET' as step;
select name, created_at, (metadata->>'size')::bigint as bytes
from storage.objects
where bucket_id = 'cattle-public'
order by created_at desc limit 10;

-- 3. Did any file reach the private bucket?
select '3. FILES IN PRIVATE BUCKET' as step;
select name, created_at, (metadata->>'size')::bigint as bytes
from storage.objects
where bucket_id = 'cattle-photos'
order by created_at desc limit 10;

-- 4. What photo records exist, and of what kind?
--    Only kind = 'profile' is ever copied to the public bucket.
select '4. PHOTO RECORDS' as step;
select c.tag_code, p.kind, p.storage_path, p.taken_at, p.locked_at is not null as locked
from cattle_photos p join cattle c on c.id = p.cattle_id
order by p.taken_at desc limit 10;

-- 5. Is the public pointer saved on the animal?
--    If this is null, the tap page has nothing to show even when a
--    file exists in the bucket.
select '5. PUBLIC POINTER' as step;
select tag_code, public_photo_path from cattle order by tag_code;

-- 6. What does the tap page actually receive?
select '6. WHAT THE PUBLIC PAGE GETS' as step;
select * from public_tag_lookup('YT-008000');

-- ============================================================
-- READING THE RESULT
--
-- Block 1 wrong  -> create the bucket, or flip it to public
-- Block 2 empty  -> the upload never ran. Did you choose
--                   "Бүтэн бие"? Only that kind goes public.
-- Block 4 shows only 'muzzle' -> same cause as above
-- Block 5 null but block 2 has files -> the pointer write failed;
--                   run schema_v14_photo_fix.sql
-- Block 6 photo_path null -> same as block 5
-- ============================================================
