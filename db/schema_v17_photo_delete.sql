-- ============================================================
-- YAK-TAG — schema patch v17
-- Super admin can delete a photo. Nobody can change one.
--
-- Rationale: replacing a photo needs a replacement, and the super
-- admin is not standing next to the animal. Delete, and the herder
-- takes a new one. One action, no ambiguity about which image is
-- authoritative.
-- ============================================================

create or replace function delete_photo(photo_id uuid, reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  p record;
  was_public boolean;
begin
  select * into p from cattle_photos where id = photo_id;
  if not found then raise exception 'Photo not found'; end if;

  if not is_super() then
    raise exception 'Only the super admin can delete a photo';
  end if;

  -- was this the one the public page shows?
  select (c.public_photo_path is not null
          and c.public_photo_path like '%' || split_part(p.storage_path, '/', 3) || '%')
    into was_public
    from cattle c where c.id = p.cattle_id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (p.farm_id, auth.uid(), 'photo_delete', 'cattle_photos', photo_id,
          jsonb_build_object('reason', reason,
                             'storage_path', p.storage_path,
                             'kind', p.kind,
                             'taken_at', p.taken_at,
                             'was_public', coalesce(was_public,false)));

  -- clearing the public pointer lets the page re-publish the next
  -- profile photo automatically, instead of leaving a dead link
  if p.kind = 'profile' then
    update cattle set public_photo_path = null where id = p.cattle_id;
  end if;

  -- the lock guard would block the delete, so clear it first
  update cattle_photos set locked_at = null, locked_by = null where id = photo_id;
  delete from cattle_photos where id = photo_id;
end $$;

-- ============================================================
-- Only the super admin may delete photo rows.
-- ============================================================
drop policy if exists photos_delete on cattle_photos;
create policy photos_delete on cattle_photos for delete
  using (is_super());

drop policy if exists photos_update on cattle_photos;
create policy photos_update on cattle_photos for update
  using (is_super());
