-- ============================================================
-- YAK-TAG — schema patch v36
-- Replace an animal's tag (the tag fell off, broke or was lost).
--
-- All history — milk, vaccines, feeding, scans, pregnancies, photos —
-- belongs to the animal (cattle.id), not to the tag, so it all stays.
-- What changes:
--   cattle.tag_id / tag_code          -> the new tag
--   new tag                           -> status 'assigned'
--   old tag                           -> 'lost' or 'retired' (+ reason);
--                                        nobody can register on it again
--   calves whose mother_tag was the old code, and breeding entries
--   whose sire_tag was the old code   -> the new code, so family links hold
--
-- Rules: the new tag must exist, belong to the animal's farm, and be
-- free (blank / written / recycled, no animal on it). Allowed for the
-- super admin or the admin of the animal's farm (null-safe check).
--
-- Safe on the live project and safe to run twice.
-- ============================================================

create or replace function admin_replace_tag(
  p_cattle_id    uuid,
  p_new_tag_code text,
  p_old_status   text default 'lost',     -- 'lost' | 'retired'
  p_reason       text default null
) returns void language plpgsql security definer set search_path = public as $$
declare
  c        record;
  nt       record;
  v_old    text;
  v_old_id uuid;
begin
  select id, farm_id, tag_id, tag_code into c from cattle where id = p_cattle_id for update;
  if not found then raise exception 'Мал олдсонгүй.'; end if;
  if not coalesce(is_super() or (my_role() = 'farm_admin' and c.farm_id = my_farm()), false) then
    raise exception 'Зөвхөн админ таг солино.';
  end if;
  if p_old_status not in ('lost', 'retired') then raise exception 'Хуучин тагийн төлөв буруу.'; end if;

  select * into nt from tags where tag_code = upper(trim(p_new_tag_code)) for update;
  if not found then raise exception 'Шинэ таг олдсонгүй: %', upper(trim(p_new_tag_code)); end if;
  if nt.tag_code = c.tag_code then raise exception 'Энэ таг аль хэдийн энэ малд байна.'; end if;
  if nt.farm_id <> c.farm_id then
    raise exception 'Шинэ таг өөр фермийнх. Эхлээд "Тагууд" хэсгээс энэ фермд оноо.';
  end if;
  if nt.status not in ('blank', 'written', 'recycled')
     or exists (select 1 from cattle x where x.tag_id = nt.id or x.tag_code = nt.tag_code) then
    raise exception 'Шинэ таг чөлөөтэй биш (ашиглагдсан, алдагдсан эсвэл хасагдсан).';
  end if;

  v_old := c.tag_code;
  v_old_id := coalesce(c.tag_id, (select id from tags where tag_code = c.tag_code));

  -- the animal takes the new tag; its history stays on cattle.id
  update cattle set tag_id = nt.id, tag_code = nt.tag_code where id = c.id;
  update tags set status = 'assigned' where id = nt.id;

  -- the old tag is out of use for good
  if v_old_id is not null then
    update tags
       set status = p_old_status,
           retired_at = case when p_old_status = 'retired' then now() else retired_at end,
           retire_reason = coalesce(nullif(trim(p_reason), ''), retire_reason)
     where id = v_old_id;
  end if;

  -- keep family links pointing at the animal's current tag
  if v_old is not null then
    update cattle set mother_tag = nt.tag_code where mother_tag = v_old;
    update repro_events set sire_tag = nt.tag_code where sire_tag = v_old;
  end if;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (c.farm_id, auth.uid(), 'tag_replace', 'cattle', c.id,
          jsonb_build_object('old_tag', v_old, 'new_tag', nt.tag_code,
                             'old_status', p_old_status, 'reason', p_reason));
end $$;

revoke all on function admin_replace_tag(uuid, text, text, text) from public, anon;
grant execute on function admin_replace_tag(uuid, text, text, text) to authenticated;

notify pgrst, 'reload schema';
