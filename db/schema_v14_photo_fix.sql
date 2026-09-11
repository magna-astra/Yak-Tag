-- ============================================================
-- YAK-TAG — schema patch v14
--
-- BUG: taking a profile photo uploaded the file but the public
-- page still showed nothing.
--
-- Cause: cow.html wrote public_photo_path with a direct UPDATE on
-- cattle. The cattle update policy does not grant herders that
-- column, so the write was silently rejected — the upload
-- succeeded, the pointer never got saved, and the tap page had
-- nothing to display.
--
-- Fix: a security-definer function, same pattern as the other
-- herder actions.
-- ============================================================

-- ============================================================
-- 1. SAVE THE PUBLIC PHOTO POINTER
-- ============================================================
create or replace function set_public_photo(
  p_cattle_id uuid,
  p_path      text
) returns void language plpgsql security definer set search_path = public as $$
declare c record;
begin
  select * into c from cattle where id = p_cattle_id;
  if not found then raise exception 'Animal not found'; end if;

  if not (is_super()
          or (my_role() = 'farm_admin' and c.farm_id = my_farm())
          or (my_role() = 'herder' and c.owner_id = auth.uid())) then
    raise exception 'Not allowed';
  end if;

  update cattle set public_photo_path = p_path where id = p_cattle_id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (c.farm_id, auth.uid(), 'set_public_photo', 'cattle', p_cattle_id,
          jsonb_build_object('path', p_path));
end $$;

-- ============================================================
-- 2. BACKFILL
--    If a profile photo already exists in the private bucket but
--    public_photo_path is empty, point at it so nothing is lost.
--    (The file still needs copying to the public bucket — the app
--     does that next time a profile photo is taken.)
-- ============================================================
-- deliberately not automatic: copying between buckets needs the
-- storage API, which SQL cannot do. Re-take the photo instead.

-- ============================================================
-- 3. STORAGE POLICIES FOR THE PUBLIC BUCKET
--    Re-stated so v14 works even if v11 partly failed.
-- ============================================================
do $$
begin
  execute $p$
    create policy "public photo insert"
    on storage.objects for insert to authenticated
    with check (bucket_id = 'cattle-public')
  $p$;
exception when duplicate_object then null;
end $$;

do $$
begin
  execute $p$
    create policy "public photo update"
    on storage.objects for update to authenticated
    using (bucket_id = 'cattle-public')
  $p$;
exception when duplicate_object then null;
end $$;

-- ============================================================
-- DIAGNOSE — run these to see where it broke
-- ============================================================
-- Does the bucket exist and is it public?
--   select id, name, public from storage.buckets;
--     -> cattle-public must show public = true
--
-- Did any file actually upload?
--   select name, bucket_id, created_at from storage.objects
--    where bucket_id = 'cattle-public' order by created_at desc limit 10;
--
-- Is the pointer saved on the animal?
--   select tag_code, public_photo_path from cattle order by tag_code;
--
-- What does the public page receive?
--   select * from public_tag_lookup('YT-008000');
-- ============================================================
