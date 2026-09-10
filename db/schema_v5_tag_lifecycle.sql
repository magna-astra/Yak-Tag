-- ============================================================
-- YAK-TAG — schema patch v5
-- Tag lifecycle: retire, recycle, reassign.
--
-- The physical tag and the animal are separate things. A tag can
-- outlive an animal (cow sold, tag recovered and reused) and an
-- animal can outlive a tag (tag lost, animal retagged).
-- ============================================================

-- ============================================================
-- 1. TRACK REWRITES
-- ============================================================
alter table tags
  add column if not exists write_count   integer not null default 0,
  add column if not exists last_wiped_at timestamptz,
  add column if not exists protected     boolean not null default false,
  add column if not exists retired_at    timestamptz,
  add column if not exists retire_reason text;

-- 'recycled' = was on an animal, wiped, ready to reissue
alter table tags drop constraint if exists tags_status_check;
alter table tags add constraint tags_status_check
  check (status in ('blank','written','assigned','lost','retired','recycled'));

-- ============================================================
-- 2. RETIRE A TAG
--    Use when a tag is permanently locked, physically damaged,
--    or lost. It can never be reissued.
-- ============================================================
create or replace function retire_tag(p_tag_code text, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  t record;
begin
  select * into t from tags where tag_code = p_tag_code;
  if not found then raise exception 'Tag % not found', p_tag_code; end if;

  if not (is_super() or (my_role() = 'farm_admin' and t.farm_id = my_farm())) then
    raise exception 'Only a farm admin can retire a tag';
  end if;

  -- detach from any animal first, so the cow is not left pointing at a dead tag
  update cattle set tag_id = null where tag_id = t.id;

  update tags
     set status = 'retired', retired_at = now(), retire_reason = p_reason
   where id = t.id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (t.farm_id, auth.uid(), 'tag_retire', 'tags', t.id,
          jsonb_build_object('tag_code', p_tag_code, 'reason', p_reason));
end $$;

-- ============================================================
-- 3. RECYCLE A TAG
--    Use when a tag is physically recovered and wiped, and you
--    want to issue it to a different animal.
--
--    Guard: refuses if the current animal is still active. You
--    must close that animal out first (sold/dead/lost/stolen).
--    This is what stops a tag pointing at one cow while the
--    database points at another.
-- ============================================================
create or replace function recycle_tag(p_tag_code text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  t record;
  c record;
begin
  select * into t from tags where tag_code = p_tag_code;
  if not found then raise exception 'Tag % not found', p_tag_code; end if;

  if not (is_super() or (my_role() = 'farm_admin' and t.farm_id = my_farm())) then
    raise exception 'Only a farm admin can recycle a tag';
  end if;

  if t.retired_at is not null then
    raise exception 'Tag % is retired and cannot be recycled', p_tag_code;
  end if;

  select * into c from cattle where tag_id = t.id;
  if found and c.status = 'active' then
    raise exception
      'Cannot recycle: % is still on an active animal (%). Close that animal out first.',
      p_tag_code, c.id;
  end if;

  -- detach from the old animal, keeping the animal's history intact
  update cattle set tag_id = null where tag_id = t.id;

  update tags
     set status = 'recycled',
         nfc_uid = null,              -- new UID gets recorded on rewrite
         last_wiped_at = now(),
         write_count = write_count + 1
   where id = t.id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (t.farm_id, auth.uid(), 'tag_recycle', 'tags', t.id,
          jsonb_build_object('tag_code', p_tag_code, 'note', p_note,
                             'previous_cattle_id', c.id));
end $$;

-- ============================================================
-- 4. RECORD A PHYSICAL WRITE
--    Called after nfc_tag.py successfully writes a tag, so the
--    database knows which chip UID is on which tag code.
-- ============================================================
create or replace function record_tag_write(
  p_tag_code text,
  p_nfc_uid text,
  p_protected boolean default true
) returns void language plpgsql security definer set search_path = public as $$
declare
  t record;
begin
  select * into t from tags where tag_code = p_tag_code;
  if not found then raise exception 'Tag % not found', p_tag_code; end if;

  if not (is_super() or (my_role() = 'farm_admin' and t.farm_id = my_farm())) then
    raise exception 'Only a farm admin can write tags';
  end if;

  update tags
     set nfc_uid = p_nfc_uid,
         status = 'written',
         written_at = now(),
         protected = p_protected,
         write_count = write_count + 1
   where id = t.id;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (t.farm_id, auth.uid(), 'tag_write', 'tags', t.id,
          jsonb_build_object('tag_code', p_tag_code, 'nfc_uid', p_nfc_uid));
end $$;

-- ============================================================
-- 5. VIEW — tag inventory for the admin screen
-- ============================================================
create or replace view tag_inventory as
select
  t.id, t.farm_id, t.tag_code, t.nfc_uid, t.status,
  t.protected, t.write_count, t.written_at, t.last_wiped_at,
  t.retired_at, t.retire_reason,
  b.code            as batch_code,
  c.id              as cattle_id,
  c.status          as cattle_status,
  p.full_name       as owner_name
from tags t
join tag_batches b on b.id = t.batch_id
left join cattle c on c.tag_id = t.id
left join profiles p on p.id = c.owner_id;

alter view tag_inventory set (security_invoker = on);

-- ============================================================
-- END v5
-- ============================================================
