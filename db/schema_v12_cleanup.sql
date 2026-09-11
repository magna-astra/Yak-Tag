-- ============================================================
-- YAK-TAG — schema patch v12
-- Clean the system down to five real animals.
--
-- Removes the 55 seeded cattle, their synthetic milk history and
-- the generated scan positions. What survives: the five animals
-- carrying real NFC tags, and whatever real data you have logged
-- against them.
--
-- Farms 07 and 03 stay, empty, so you can still demonstrate that
-- a farm admin cannot see another farm's animals.
-- ============================================================

-- ============================================================
-- 1. WHAT WE ARE KEEPING
-- ============================================================
create temporary table keep_ids as
select id from cattle
 where tag_code in ('YT-008000','YT-008001','YT-008002','YT-008003','YT-008004');

do $$
declare n int;
begin
  select count(*) into n from keep_ids;
  if n <> 5 then
    raise exception 'Expected 5 demo animals, found %. Stopping before deleting anything.', n;
  end if;
  raise notice 'Keeping % animals.', n;
end $$;

-- ============================================================
-- 2. DELETE EVERYTHING ELSE
--    Order matters: children before parents.
-- ============================================================

-- photo lock trigger would block the delete, so clear locks first
update cattle_photos set locked_at = null, locked_by = null
 where cattle_id not in (select id from keep_ids);

delete from cattle_photos      where cattle_id not in (select id from keep_ids);
delete from milk_yield         where cattle_id not in (select id from keep_ids);
delete from health_events      where cattle_id not in (select id from keep_ids);
delete from scan_events        where cattle_id not in (select id from keep_ids);
delete from public_scans       where cattle_id not in (select id from keep_ids);
delete from ownership_transfers where cattle_id not in (select id from keep_ids);
delete from cattle             where id not in (select id from keep_ids);

-- ============================================================
-- 3. CLEAR THE SYNTHETIC HISTORY ON THE FIVE WE KEPT
--
-- The milk figures and scan positions were generated, not measured.
-- Leaving them in means the dashboard shows numbers nobody recorded,
-- which is worse than an empty dashboard: it looks like real data.
-- ============================================================
delete from milk_yield  where cattle_id in (select id from keep_ids);
delete from scan_events where cattle_id in (select id from keep_ids);

-- ============================================================
-- 4. FREE THE UNUSED TAGS
-- ============================================================
update tags
   set status = 'blank', nfc_uid = null, written_at = null
 where id not in (select tag_id from cattle where tag_id is not null);

-- ============================================================
-- 5. EVERYTHING ON ONE FARM, ONE HERDER
-- ============================================================
do $$
declare
  u_bat uuid := 'd422690e-534a-49b7-b510-c347b4170224';
  f12 uuid;
begin
  select id into f12 from farms where code = 'FERM-12';

  update cattle
     set owner_id = u_bat, registered_by = u_bat, farm_id = f12, status = 'active'
   where id in (select id from keep_ids);

  -- tags follow their animals
  update tags t
     set farm_id = f12
    from cattle c
   where c.tag_id = t.id and c.id in (select id from keep_ids);
end $$;

-- ============================================================
-- CHECK — run these after
-- ============================================================
-- select tag_code, status, owner_id from cattle order by tag_code;
--   -> exactly 5 rows, all YT-008000..004
--
-- select count(*) from milk_yield;    -> 0
-- select count(*) from scan_events;   -> 0  (fills as you tap real tags)
--
-- Then log in and confirm:
--   super@yaktag.test    -> 5 animals
--   admin12@yaktag.test  -> 5 animals
--   bat@yaktag.test      -> 5 animals
--   admin07@yaktag.test  -> 0 animals   (proves farm isolation still holds)
-- ============================================================
