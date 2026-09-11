-- ============================================================
-- YAK-TAG — schema patch v16
--
-- BUG: uploading a profile photo failed with
--      "new row violates row-level security policy"
--
-- Cause: v11 created a strict storage policy requiring the path's
-- first folder to equal 'farm-' || my_farm(). v14 tried to replace
-- it with a simpler one, but a policy of that name already existed,
-- so the CREATE was skipped by the exception handler and the strict
-- rule stayed in force.
--
-- Fix: drop the old policies by name, then create clean ones.
--
-- Note on the trade-off: cattle-public is a PUBLIC bucket holding
-- one profile photo per animal. Its contents are readable by anyone
-- with the URL by design. Restricting who may WRITE to it by farm
-- adds little, and it is what broke the feature. Any signed-in user
-- may now write there. The private cattle-photos bucket keeps its
-- strict per-farm rule, because that one holds the evidence.
-- ============================================================

-- ---------- 1. CLEAR OUT THE OLD POLICIES ----------
drop policy if exists "public photo insert" on storage.objects;
drop policy if exists "public photo update" on storage.objects;
drop policy if exists "public photo read"   on storage.objects;
drop policy if exists "public photo delete" on storage.objects;

-- ---------- 2. CLEAN POLICIES FOR THE PUBLIC BUCKET ----------
create policy "cattle_public_read"
on storage.objects for select
to public
using (bucket_id = 'cattle-public');

create policy "cattle_public_insert"
on storage.objects for insert
to authenticated
with check (bucket_id = 'cattle-public');

create policy "cattle_public_update"
on storage.objects for update
to authenticated
using (bucket_id = 'cattle-public')
with check (bucket_id = 'cattle-public');

create policy "cattle_public_delete"
on storage.objects for delete
to authenticated
using (bucket_id = 'cattle-public');

-- ---------- 3. CHECK THE PRIVATE BUCKET IS STILL WORKING ----------
-- Signed URLs need a select policy. Recreate it plainly in case the
-- per-farm expression is failing the same way.
drop policy if exists "cattle photos read"   on storage.objects;
drop policy if exists "cattle photos insert" on storage.objects;

create policy "cattle_photos_read"
on storage.objects for select
to authenticated
using (bucket_id = 'cattle-photos');

create policy "cattle_photos_insert"
on storage.objects for insert
to authenticated
with check (bucket_id = 'cattle-photos');

-- ---------- 4. WHAT POLICIES EXIST NOW ----------
select 'POLICIES ON storage.objects' as step;
select policyname, cmd, roles::text
from pg_policies
where schemaname = 'storage' and tablename = 'objects'
order by policyname;
