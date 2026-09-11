-- ============================================================
-- YAK-TAG — schema patch v6
-- Demo / pilot setup.
--
-- 1. Five real tags, one farm, one farmer (Bat-Erdene).
-- 2. Only the super admin may replace or delete a photo.
-- 3. A demo view so the pitch always shows tidy data.
-- ============================================================

-- ============================================================
-- 1. THE FIVE DEMO ANIMALS
--
-- Reassigns YT-008000..YT-008004 to bat@yaktag.test on Farm 12,
-- gives them clean names/data, and clears any messy seed values
-- so a live demo never shows something odd.
-- ============================================================
do $$
declare
  u_bat  uuid := 'd422690e-534a-49b7-b510-c347b4170224';
  f12    uuid;
  demo   text[] := array['YT-008000','YT-008001','YT-008002','YT-008003','YT-008004'];
  breeds text[] := array['Монгол','Монгол','Эрлийз','Монгол','Эрлийз'];
  years  int[]  := array[2021, 2020, 2022, 2019, 2021];
  weights numeric[] := array[412.0, 448.5, 386.0, 470.0, 401.5];
  sexes  text[] := array['female','female','female','male','female'];
  i int;
begin
  select id into f12 from farms where code = 'FERM-12';
  if f12 is null then
    raise exception 'Farm FERM-12 not found — was seed.sql run?';
  end if;

  for i in 1..5 loop
    update cattle
       set owner_id      = u_bat,
           registered_by = u_bat,
           farm_id       = f12,
           breed         = breeds[i],
           birth_year    = years[i],
           weight_kg     = weights[i],
           sex           = sexes[i],
           status        = 'active'
     where tag_code = demo[i];
  end loop;

  raise notice 'Five demo animals assigned to Bat-Erdene on Farm 12.';
end $$;

-- Give the demo animals believable recent milk history (last 14 days),
-- so the charts on the cow page and the dashboard are not empty during
-- a demo. Real entries the farmer makes will simply add to this.
do $$
declare
  u_bat uuid := 'd422690e-534a-49b7-b510-c347b4170224';
  rec record;
  d date;
  base numeric;
begin
  for rec in
    select id, farm_id, tag_code from cattle
     where tag_code in ('YT-008000','YT-008001','YT-008002','YT-008003','YT-008004')
       and sex = 'female'          -- males give no milk
  loop
    base := 8 + random() * 4;          -- 8-12 litres a day
    d := current_date - 13;
    while d < current_date loop
      -- occasional missed day, which is realistic
      if random() > 0.12 then
        insert into milk_yield (farm_id, cattle_id, recorded_by, liters, yield_date)
        values (rec.farm_id, rec.id, u_bat,
                round((base + (random() - 0.5) * 2.5)::numeric, 1), d)
        on conflict (cattle_id, yield_date) do nothing;
      end if;
      d := d + 1;
    end loop;
  end loop;

  raise notice 'Milk history generated for the demo animals.';
end $$;

-- ============================================================
-- 2. PHOTO CONTROL — SUPER ADMIN ONLY
--
-- Previously a farm_admin could unlock a photo. Tightened: only
-- the super admin can replace or delete one. A farm admin can
-- still SEE everything, they just cannot alter the evidence.
-- ============================================================
create or replace function unlock_photo(photo_id uuid, reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  p record;
begin
  select * into p from cattle_photos where id = photo_id;
  if not found then
    raise exception 'Photo not found';
  end if;

  if not is_super() then
    raise exception 'Only the super admin can unlock a photo';
  end if;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (p.farm_id, auth.uid(), 'photo_unlock', 'cattle_photos', photo_id,
          jsonb_build_object('reason', reason,
                             'was_locked_at', p.locked_at,
                             'was_locked_by', p.locked_by));

  update cattle_photos set locked_at = null, locked_by = null
  where id = photo_id;
end $$;

-- delete a photo record entirely — super admin only, always logged
create or replace function delete_photo(photo_id uuid, reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  p record;
begin
  select * into p from cattle_photos where id = photo_id;
  if not found then
    raise exception 'Photo not found';
  end if;

  if not is_super() then
    raise exception 'Only the super admin can delete a photo';
  end if;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (p.farm_id, auth.uid(), 'photo_delete', 'cattle_photos', photo_id,
          jsonb_build_object('reason', reason,
                             'storage_path', p.storage_path,
                             'kind', p.kind,
                             'taken_at', p.taken_at));

  -- clear the lock so the guard trigger allows the delete
  update cattle_photos set locked_at = null, locked_by = null where id = photo_id;
  delete from cattle_photos where id = photo_id;
end $$;

-- farm admins may no longer update photo rows at all
drop policy if exists photos_update on cattle_photos;
create policy photos_update on cattle_photos for update
  using (is_super());

drop policy if exists photos_delete on cattle_photos;
create policy photos_delete on cattle_photos for delete
  using (is_super());

-- ============================================================
-- 3. DEMO VIEW — the five animals, everything in one row
-- ============================================================
create or replace view demo_herd as
select
  c.tag_code, c.sex, c.birth_year, c.breed, c.weight_kg, c.status,
  p.full_name as owner_name,
  f.name      as farm_name,
  t.nfc_uid,
  t.status    as tag_status,
  (select count(*) from milk_yield m where m.cattle_id = c.id)      as milk_entries,
  (select round(sum(m.liters),1) from milk_yield m
     where m.cattle_id = c.id
       and date_trunc('month', m.yield_date) = date_trunc('month', current_date)) as milk_this_month,
  (select count(*) from cattle_photos ph where ph.cattle_id = c.id) as photo_count,
  (select count(*) from scan_events s where s.cattle_id = c.id)     as scan_count
from cattle c
join farms f    on f.id = c.farm_id
join profiles p on p.id = c.owner_id
left join tags t on t.id = c.tag_id
where c.tag_code in ('YT-008000','YT-008001','YT-008002','YT-008003','YT-008004')
order by c.tag_code;

alter view demo_herd set (security_invoker = on);

-- ============================================================
-- CHECK YOUR WORK
--   select * from demo_herd;
-- Expect 5 rows, all owned by Бат-Эрдэнэ on Наран farm,
-- with ~26 milk entries each on the females.
-- ============================================================
