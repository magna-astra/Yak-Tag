-- ============================================================
-- YAK-TAG — schema patch v39
-- Sell / give / pass on an animal to another herder.
--
-- The ownership_transfers table has existed since v1 but nothing
-- used it. Now:
--   transfer_cattle(...)         the one way to change an owner, with a
--                                reason and date, kept as history
--   cattle_ownership_history(..) the history, for the cow page and the
--                                dashboard
--
-- Rules:
--   * super admin, or the admin of the animal's farm (null-safe, v34)
--   * a farm admin can pass animals only within their own farm;
--     to another farm only the super admin
--   * the new owner must be an active user who belongs to a farm
--
-- To another farm, the animal takes its whole record along: its tag,
-- milk, vaccines, pregnancies, photos, scans and earlier transfers,
-- so the buyer's farm sees the full history and the seller's farm no
-- longer sees an animal it does not own. Photo files stay where they
-- are; a new read rule lets the animal's current farm see them.
--
-- The phone number strangers call (contact_phone) becomes the new
-- owner's number and is unlocked, so the buyer — not the seller —
-- gets the calls.
--
-- Safe on the live project and safe to run twice.
-- ============================================================

alter table ownership_transfers add column if not exists from_farm_id uuid references farms(id);

-- Direct inserts are no longer needed (and let a farm admin hand an
-- animal to a user of another farm). The function below is the way in.
drop policy if exists transfers_insert on ownership_transfers;

create or replace function transfer_cattle(
  p_cattle_id uuid,
  p_to_owner  uuid,
  p_reason    text default 'sale',   -- sale | gift | inheritance | correction | other
  p_note      text default null,
  p_date      date default null      -- when it happened; default today
) returns void language plpgsql security definer set search_path = public as $$
declare
  c       record;
  o       record;
  v_old   text;
  v_new   text;
  v_when  timestamptz;
  v_cross boolean;
  v_phone text;
begin
  select id, farm_id, owner_id, tag_id, tag_code into c from cattle where id = p_cattle_id for update;
  if not found then raise exception 'Мал олдсонгүй.'; end if;
  if not coalesce(is_super() or (my_role() = 'farm_admin' and c.farm_id = my_farm()), false) then
    raise exception 'Малыг зөвхөн админ шилжүүлнэ.';
  end if;
  if coalesce(p_reason, '') not in ('sale', 'gift', 'inheritance', 'correction', 'other') then
    raise exception 'Шалтгаанаа сонгоно уу.';
  end if;
  if p_date is not null and p_date > current_date then
    raise exception 'Огноо ирээдүй байж болохгүй.';
  end if;

  select id, farm_id, status, full_name, phone into o from profiles where id = p_to_owner;
  if not found or o.status <> 'active' then raise exception 'Шинэ эзэмшигч олдсонгүй эсвэл идэвхгүй.'; end if;
  if o.farm_id is null then raise exception 'Шинэ эзэмшигч аль нэг фермд бүртгэлгүй байна.'; end if;
  if o.id = c.owner_id then raise exception 'Энэ хүн аль хэдийн эзэмшигч нь байна.'; end if;

  v_cross := o.farm_id <> c.farm_id;
  if v_cross and not is_super() then
    raise exception 'Өөр ферм рүү зөвхөн ерөнхий админ шилжүүлнэ.';
  end if;
  if v_cross and not exists (select 1 from farms where id = o.farm_id and status = 'active') then
    raise exception 'Хүлээн авах ферм идэвхгүй байна.';
  end if;

  v_when := case when p_date is null or p_date = current_date then now()
                 else (p_date + time '12:00') at time zone 'Asia/Ulaanbaatar' end;

  if v_cross then
    -- the photo lock (v19) lets admin functions through with this flag,
    -- for this transaction only
    perform set_config('yaktag.photo_admin', 'on', true);
    update cattle              set farm_id = o.farm_id where id = c.id;
    update tags                set farm_id = o.farm_id where id = c.tag_id or tag_code = c.tag_code;
    update health_events       set farm_id = o.farm_id where cattle_id = c.id;
    update repro_events        set farm_id = o.farm_id where cattle_id = c.id;
    update milk_yield          set farm_id = o.farm_id where cattle_id = c.id;
    update scan_events         set farm_id = o.farm_id where cattle_id = c.id;
    update public_scans        set farm_id = o.farm_id where cattle_id = c.id;
    update cattle_photos       set farm_id = o.farm_id where cattle_id = c.id;
    update ownership_transfers set farm_id = o.farm_id where cattle_id = c.id;
    perform set_config('yaktag.photo_admin', 'off', true);
  end if;

  -- the new owner's number, if it is a valid phone number (v21 rule)
  v_phone := case when o.phone ~ '^\+?[0-9][0-9 ()-]{5,19}$' then o.phone end;

  insert into ownership_transfers (farm_id, from_farm_id, cattle_id, from_owner, to_owner,
                                   reason, note, transferred_at, recorded_by)
  values (o.farm_id, c.farm_id, c.id, c.owner_id, o.id,
          p_reason, nullif(trim(p_note), ''), v_when, auth.uid());

  -- the v1 trigger apply_transfer also sets owner_id; set it here too
  update cattle
     set owner_id = o.id,
         contact_phone = v_phone,
         contact_locked_at = null,
         contact_locked_by = null
   where id = c.id;

  select full_name into v_old from profiles where id = c.owner_id;
  v_new := o.full_name;
  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (o.farm_id, auth.uid(), 'cattle_transfer', 'cattle', c.id,
          jsonb_build_object('tag_code', c.tag_code, 'from', v_old, 'to', v_new,
                             'reason', p_reason, 'note', nullif(trim(p_note), ''),
                             'from_farm', (select code from farms where id = c.farm_id),
                             'to_farm', (select code from farms where id = o.farm_id)));
  if v_cross then       -- the seller's farm keeps a line in its own history
    insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
    values (c.farm_id, auth.uid(), 'cattle_transfer', 'cattle', c.id,
            jsonb_build_object('tag_code', c.tag_code, 'from', v_old, 'to', v_new, 'reason', p_reason,
                               'to_farm', (select code from farms where id = o.farm_id)));
  end if;
end $$;

-- History for anyone who can see the animal. The note (e.g. a price)
-- only for admins.
create or replace function cattle_ownership_history(p_cattle_id uuid)
returns table (transferred_at timestamptz, from_name text, to_name text,
               reason text, note text, from_farm text, to_farm text)
language sql stable security definer set search_path = public as $$
  select t.transferred_at, pf.full_name, pt.full_name, t.reason,
         case when is_super() or my_role() = 'farm_admin' then t.note end,
         ff.code, ft.code
  from ownership_transfers t
  join cattle c on c.id = t.cattle_id
  left join profiles pf on pf.id = t.from_owner
  left join profiles pt on pt.id = t.to_owner
  left join farms ff on ff.id = t.from_farm_id
  left join farms ft on ft.id = t.farm_id
  where t.cattle_id = p_cattle_id
    and coalesce(is_super() or c.farm_id = my_farm(), false)
  order by t.transferred_at desc
$$;

revoke all on function transfer_cattle(uuid, uuid, text, text, date) from public, anon;
revoke all on function cattle_ownership_history(uuid) from public, anon;
grant execute on function transfer_cattle(uuid, uuid, text, text, date) to authenticated;
grant execute on function cattle_ownership_history(uuid) to authenticated;

-- ============================================================
-- Photos of an animal that moved farms: files stay in the old farm's
-- folder (farm-<old>/cow-<id>/…). This extra read rule lets the
-- animal's current farm open them. It only adds access; the existing
-- rules are untouched.
-- ============================================================
drop policy if exists "cattle_photos_read_moved" on storage.objects;
create policy "cattle_photos_read_moved"
on storage.objects for select
to authenticated
using (
  bucket_id = 'cattle-photos'
  and exists (
    select 1 from public.cattle c
    where (storage.foldername(name))[2] = 'cow-' || c.id::text
      and c.farm_id = public.my_farm()
  )
);

notify pgrst, 'reload schema';
