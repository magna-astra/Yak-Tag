-- ============================================================
-- YAK-TAG — system check
-- Run this any time. It changes nothing, only reports.
-- ============================================================

-- ---------- 1. WHAT ANIMALS EXIST ----------
select '1. CATTLE' as check;
select tag_code, sex, birth_year, breed, status,
       contact_phone is not null as has_phone,
       contact_locked_at is not null as phone_locked,
       public_photo_path is not null as has_public_photo
from cattle order by tag_code;

-- ---------- 2. TAGS AND THEIR CHIPS ----------
select '2. TAGS — nfc_uid should be filled for tags you wrote' as check;
select t.tag_code, t.status, t.nfc_uid, t.written_at,
       c.tag_code as on_animal
from tags t
left join cattle c on c.tag_id = t.id
where t.nfc_uid is not null or c.id is not null
order by t.tag_code;

-- ---------- 3. FARMS ----------
select '3. FARMS' as check;
select f.code, f.name, f.aimag, f.soum, f.status,
       (select count(*) from cattle c where c.farm_id = f.id) as cattle,
       (select count(*) from profiles p where p.farm_id = f.id) as users
from farms f order by f.code;

-- ---------- 4. USERS ----------
select '4. USERS' as check;
select p.full_name, p.role, f.code as farm, p.active,
       (select count(*) from cattle c where c.owner_id = p.id) as owns
from profiles p left join farms f on f.id = p.farm_id
order by p.role, p.full_name;

-- ---------- 5. REAL ACTIVITY ----------
select '5. ACTIVITY — all should reflect real use only' as check;
select
  (select count(*) from milk_yield)    as milk_entries,
  (select count(*) from scan_events)   as app_scans,
  (select count(*) from public_scans)  as public_taps,
  (select count(*) from cattle_photos) as photos,
  (select count(*) from health_events) as health_events;

-- ---------- 6. VIEWS RESPECT RLS ----------
-- security_invoker must be true on every view, or logged-in users
-- read them as the view owner and see everything.
select '6. VIEW SECURITY — all must be true' as check;
select c.relname as view_name,
       coalesce(
         (select option_value = 'true'
            from pg_options_to_table(c.reloptions)
           where option_name = 'security_invoker'), false) as security_invoker
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where c.relkind = 'v' and n.nspname = 'public'
order by c.relname;

-- ---------- 7. RLS ENABLED ON EVERY TABLE ----------
select '7. RLS — all must be true' as check;
select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
order by tablename;

-- ---------- 8. PUBLIC LOOKUP IS MINIMAL ----------
select '8. PUBLIC LOOKUP — must return 5 columns only' as check;
select * from public_tag_lookup('YT-008000');

-- ---------- 9. FUNCTIONS PRESENT ----------
select '9. FUNCTIONS' as check;
select proname
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and proname in ('public_tag_lookup','record_public_scan','set_contact_phone',
                  'unlock_contact_phone','log_vaccination','log_feeding',
                  'report_lost','report_found','delete_cattle','delete_farm',
                  'delete_profile','delete_tag','archive_farm','create_farm',
                  'admin_update_cattle','admin_update_profile','unlock_photo',
                  'delete_photo','retire_tag','recycle_tag','record_tag_write')
order by proname;

-- ---------- 10. STORAGE BUCKETS ----------
select '10. BUCKETS — cattle-photos private, cattle-public public' as check;
select id, name, public from storage.buckets order by name;
