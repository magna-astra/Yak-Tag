-- ============================================================
-- YAK-TAG — schema patch v27
-- Tags tab: the super admin manages tag stock in the dashboard.
--
-- Until now tags could only be created, moved between farms or
-- marked lost in SQL. The dashboard showed animals only, so a
-- written tag waiting for a herder was invisible.
--
-- Adds one read view and three super-admin functions. No table or
-- data changes. Safe on the live project and safe to run twice.
-- ============================================================

-- ============================================================
-- 1. TAG LIST
--
-- stage — the one word the dashboard shows:
--   blank    no chip written yet
--   written  chip written, waiting for a herder to register an animal
--   assigned an animal is registered on it
--   lost / retired
-- ============================================================
create or replace view admin_tag_list as
select
  t.id, t.tag_code, t.status, t.nfc_uid, t.protected,
  t.written_at, t.created_at, t.retired_at, t.retire_reason,
  t.farm_id, f.code as farm_code, f.name as farm_name,
  b.code as batch_code,
  c.id as cattle_id, c.status as cattle_status,
  p.full_name as owner_name,
  case
    when c.id is not null                   then 'assigned'
    when t.status in ('lost', 'retired')    then t.status
    when t.nfc_uid is not null
      or t.status in ('written', 'recycled') then 'written'
    else 'blank'
  end as stage
from tags t
join farms f            on f.id = t.farm_id
left join tag_batches b on b.id = t.batch_id
left join cattle c      on c.tag_id = t.id
left join profiles p    on p.id = c.owner_id;

alter view admin_tag_list set (security_invoker = on);   -- row security applies

-- ============================================================
-- 2. CREATE TAG CODES FOR A RANGE
--
-- Codes look like YT-008005: prefix, dash, number padded to 6.
-- Number ranges live in tag_batches, which may never overlap
-- (constraint no_range_overlap). So:
--   range inside one existing batch  -> add codes to that batch
--   range touching no batch          -> new batch for the range
--   range half inside a batch        -> refused, with the batch named
-- Codes that already exist are skipped, so re-running is harmless.
-- ============================================================
create or replace function admin_create_tags(
  p_prefix  text,
  p_from    integer,
  p_to      integer,
  p_farm_id uuid
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_prefix  text := upper(trim(p_prefix));
  b         record;
  v_batch   uuid;
  v_created int;
begin
  if not is_super() then raise exception 'Зөвхөн ерөнхий админ.'; end if;
  if v_prefix !~ '^[A-Z]{1,6}$' then raise exception 'Угтвар зөвхөн латин үсэг (жишээ: YT).'; end if;
  if p_from is null or p_to is null or p_from < 0 or p_to < p_from then
    raise exception 'Дугаарын хүрээ буруу.';
  end if;
  if p_to > 999999 then raise exception 'Дугаар 999999-аас их байж болохгүй.'; end if;
  if p_to - p_from + 1 > 2000 then raise exception 'Нэг удаад 2000-аас ихгүй таг.'; end if;
  if not exists (select 1 from farms where id = p_farm_id) then
    raise exception 'Ферм олдсонгүй.';
  end if;

  -- Which batch does this range belong to?
  select * into b from tag_batches
  where int4range(range_start, range_end, '[]') && int4range(p_from, p_to, '[]')
  order by range_start limit 1;

  if found then
    if p_from < b.range_start or p_to > b.range_end then
      raise exception 'Хүрээ % багцтай (% – %) хэсэгчлэн давхцаж байна. Тэр багц дотор эсвэл гадна хүрээ сонгоно уу.',
        b.code, b.range_start, b.range_end;
    end if;
    v_batch := b.id;
  else
    insert into tag_batches (farm_id, code, prefix, range_start, range_end, status)
    values (p_farm_id, v_prefix || '-' || p_from || '-' || p_to, v_prefix, p_from, p_to, 'issued')
    returning id into v_batch;
  end if;

  insert into tags (farm_id, batch_id, tag_code, qr_slug, status)
  select p_farm_id, v_batch,
         v_prefix || '-' || lpad(n::text, 6, '0'),
         substr(replace(gen_random_uuid()::text, '-', ''), 1, 12),
         'blank'
  from generate_series(p_from, p_to) n
  on conflict (tag_code) do nothing;
  get diagnostics v_created = row_count;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (p_farm_id, auth.uid(), 'tags_create', 'tag_batches', v_batch,
          jsonb_build_object('prefix', v_prefix, 'from', p_from, 'to', p_to,
                             'created', v_created));

  return jsonb_build_object('created', v_created,
                            'skipped', (p_to - p_from + 1) - v_created);
end $$;

-- ============================================================
-- 3. MOVE TAGS TO A FARM
--
-- This is how the admin "chooses the farm": a herder can only
-- register an animal on a tag of their own farm. Tags that already
-- carry an animal are not moved (the animal's farm is changed on
-- the animal instead, in the herd table).
-- ============================================================
create or replace function admin_assign_tags(p_codes text[], p_farm_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_moved int;
begin
  if not is_super() then raise exception 'Зөвхөн ерөнхий админ.'; end if;
  if not exists (select 1 from farms where id = p_farm_id) then
    raise exception 'Ферм олдсонгүй.';
  end if;

  update tags t set farm_id = p_farm_id
  where t.tag_code = any(p_codes)
    and t.farm_id <> p_farm_id
    and t.status not in ('assigned', 'retired')
    and not exists (select 1 from cattle c
                    where c.tag_id = t.id or c.tag_code = t.tag_code);
  get diagnostics v_moved = row_count;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (p_farm_id, auth.uid(), 'tags_assign_farm', 'tags', null,
          jsonb_build_object('codes', to_jsonb(p_codes), 'moved', v_moved));

  return jsonb_build_object('moved', v_moved,
                            'skipped', coalesce(array_length(p_codes, 1), 0) - v_moved);
end $$;

-- ============================================================
-- 4. MARK LOST / RETIRED, OR RESTORE
--
-- lost    — fell off or went missing. If it was on an animal, the
--           animal keeps all its history; only the link to the chip
--           is cleared (same as retire_tag in v5). The code stays
--           on the animal record, so nobody can register it again.
-- retired — broken or destroyed; permanent.
-- restore — a lost tag was found: back to blank/written, only if
--           no animal has it.
-- ============================================================
create or replace function admin_tag_status(p_codes text[], p_action text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_n int;
begin
  if not is_super() then raise exception 'Зөвхөн ерөнхий админ.'; end if;

  if p_action in ('lost', 'retired') then
    update cattle c set tag_id = null
    from tags t
    where c.tag_id = t.id and t.tag_code = any(p_codes) and t.status <> 'retired';

    update tags set status = p_action,
                    retired_at = case when p_action = 'retired' then now() else retired_at end,
                    retire_reason = coalesce(nullif(trim(p_reason), ''), retire_reason)
    where tag_code = any(p_codes) and status <> 'retired';
    get diagnostics v_n = row_count;

  elsif p_action = 'restore' then
    update tags t
       set status = case when t.nfc_uid is not null then 'written' else 'blank' end,
           retire_reason = null
    where t.tag_code = any(p_codes) and t.status = 'lost'
      and not exists (select 1 from cattle c
                      where c.tag_id = t.id or c.tag_code = t.tag_code);
    get diagnostics v_n = row_count;
  else
    raise exception 'Unknown action %', p_action;
  end if;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (null, auth.uid(), 'tags_' || p_action, 'tags', null,
          jsonb_build_object('codes', to_jsonb(p_codes), 'changed', v_n, 'reason', p_reason));

  return jsonb_build_object('changed', v_n,
                            'skipped', coalesce(array_length(p_codes, 1), 0) - v_n);
end $$;

revoke all on function admin_create_tags(text, integer, integer, uuid) from public, anon;
revoke all on function admin_assign_tags(text[], uuid)                 from public, anon;
revoke all on function admin_tag_status(text[], text, text)            from public, anon;
grant execute on function admin_create_tags(text, integer, integer, uuid) to authenticated;
grant execute on function admin_assign_tags(text[], uuid)                 to authenticated;
grant execute on function admin_tag_status(text[], text, text)            to authenticated;

notify pgrst, 'reload schema';

-- ============================================================
-- CHECK AFTER RUNNING (as super admin in the dashboard, or here):
--   select stage, count(*) from admin_tag_list group by 1;
-- ============================================================
