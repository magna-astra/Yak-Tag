-- Role tests for schema_v49 on the local replay DB. Everything runs in
-- one transaction and is rolled back at the end: the DB stays as it was.
\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
begin;

create schema t;
grant usage on schema t to public;
create function t.ok(cond boolean, label text) returns text language plpgsql as $$
begin
  if not coalesce(cond, false) then raise exception 'FAIL: %', label; end if;
  return 'ok   ' || label;
end $$;
create function t.err(q text, pat text, label text) returns text language plpgsql as $$
begin
  execute q;
  raise exception 'FAIL (no error): %', label;
exception when others then
  if sqlerrm like 'FAIL (no error)%' then raise; end if;
  if sqlerrm !~* pat then raise exception 'FAIL: % — got: %', label, sqlerrm; end if;
  return 'ok   ' || label || '  →  ' || sqlerrm;
end $$;
create function t.n(q text) returns bigint language plpgsql as $$
declare v bigint; begin execute 'select count(*) from (' || q || ') x' into v; return v; end $$;
create function t.as_(u text) returns void language sql as $$
  select set_config('request.jwt.claims',
    case when u is null then '' else json_build_object('sub', u, 'role', 'authenticated')::text end, false)
$$;
grant execute on all functions in schema t to public;

-- people
\set SUPER  '00000000-0000-0000-0000-000000000001'
\set FA12   '00000000-0000-0000-0000-000000000002'
\set FA07   '00000000-0000-0000-0000-000000000003'
\set H12    '00000000-0000-0000-0000-000000000004'
\set ADM    'aaaaaaaa-0000-0000-0000-000000000001'
\set ADM2   'aaaaaaaa-0000-0000-0000-000000000002'
\set HA     'aaaaaaaa-0000-0000-0000-000000000011'
\set HA2    'aaaaaaaa-0000-0000-0000-000000000012'

insert into auth.users (id, email) values (:'ADM', 'adm@x.test'), (:'ADM2', 'adm2@x.test'),
  (:'HA', '99112233@yaktag.invalid'), (:'HA2', '99112244@yaktag.invalid');
-- what the Edge Function does for "Админ" (no farm)
insert into profiles (id, full_name, role, farm_id) values
  (:'ADM', 'Админ А', 'admin', null), (:'ADM2', 'Админ Б', 'admin', null);
select t.ok(true, 'admin profile without a farm is allowed');
select t.err($$insert into profiles (id, full_name, role) values ('aaaaaaaa-0000-0000-0000-0000000000ff', 'x', 'herder')$$,
             'farm_required', 'herder without a farm is still refused');

select id as f12 from farms where code = 'FERM-12' \gset
select id as f07 from farms where code = 'FERM-07' \gset
select id as f03 from farms where code = 'FERM-03' \gset
select tag_code as t12 from tags where farm_id = :'f12' and status in ('blank','written','recycled')
  and not exists (select 1 from cattle c where c.tag_id = tags.id) order by tag_code limit 1 \gset
select tag_code as t07 from tags where farm_id = :'f07' and status in ('blank','written','recycled') order by tag_code limit 1 \gset
select tag_code as t07b from tags where farm_id = :'f07' and status in ('blank','written','recycled') order by tag_code offset 1 limit 1 \gset
select tag_code as c12 from cattle where farm_id = :'f12' order by tag_code limit 1 \gset

-- ================= Админ А =================
set role authenticated;
select t.as_(:'ADM');
select t.ok((select count(*) from farms) = 0, 'Админ sees no farm before creating one');
select create_farm('ADM-1', 'Админы ферм', 'Төв', 'Зуунмод') as fa \gset
select create_farm('ADM-2', 'Хоёр дахь ферм', 'Төв', null) as fa2 \gset
select t.ok((select count(*) from farms) = 2, 'Админ sees exactly his 2 farms');
select t.ok((select count(*) from admin_farms) = 2, 'admin_farms view: his 2 farms');
select t.ok((select count(*) from cattle) = 0, 'Админ sees no animals of other farms');
select t.ok((select count(*) from tags) = 0, 'Админ sees no tags of other farms');
select t.ok((select count(*) from profiles) = 1, 'Админ sees only himself (no users yet)');
select t.ok((select count(*) from audit_log) = 0, 'Админ cannot read the system history');
select t.ok(admin_owns_farm(:'fa') and not admin_owns_farm(:'f12'), 'admin_owns_farm');
select admin_update_farm(:'fa', 'ADM-1', 'Админы ферм 1', 'Төв', 'Зуунмод', 47.9, 106.9);
select t.ok((select name from farms where id = :'fa') = 'Админы ферм 1', 'Админ edits his own farm');
select t.err(format($$select admin_update_farm(%L, 'FERM-12', 'x', null, null, null, null)$$, :'f12'),
             'засах эрхгүй', 'Админ cannot edit another farm');
select t.err(format($$select delete_farm(%L, true)$$, :'fa'), 'Super admin only', 'Админ cannot delete a farm');
select t.err(format($$select archive_farm(%L)$$, :'fa'), 'Super admin only', 'Админ cannot pause a farm');
select t.err($$select admin_pause_tags(array['YT-000001'], true)$$, 'ерөнхий', 'Админ cannot pause tags');
select t.err($$select admin_create_tags('YT', 1, 2, null)$$, 'ерөнхий', 'Админ cannot create tag numbers');
select t.err($$select delete_profile('00000000-0000-0000-0000-000000000004')$$, 'Super admin only', 'Админ cannot delete users');
update farms set name = 'x';
reset role;
select t.ok((select count(*) from farms where name = 'x') = 0, '… and nothing was changed');
select t.ok((select created_by from farms where id = :'fa') = :'ADM', 'created_by is set');
-- the Edge Function creates his herders
insert into profiles (id, full_name, phone, role, farm_id) values
  (:'HA', 'Малчин А', '99112233', 'herder', :'fa'), (:'HA2', 'Малчин Б', '99112244', 'herder', :'fa2');

set role authenticated;
select t.as_(:'ADM');
select t.ok((select count(*) from profiles) = 3, 'Админ sees himself + his 2 herders');
select t.ok((select count(*) from admin_users) = 3, 'admin_users view: same 3');
select admin_update_profile(:'HA', 'Малчин А2', null, null, null, false);
select t.ok((select full_name from profiles where id = :'HA') = 'Малчин А2'
            and (select active from profiles where id = :'HA'), 'Админ renames his herder (cannot switch him off)');
select admin_update_profile(:'HA2', null, null, 'farm_admin', :'fa', null);
select t.ok((select role || farm_id::text from profiles where id = :'HA2') = 'farm_admin' || :'fa',
            'Админ makes his herder a farm admin and moves him between his farms');
select admin_update_profile(:'HA2', null, null, 'herder', :'fa2', null);
select t.err(format($$select admin_update_profile(%L, null, null, 'admin')$$, :'HA'), 'малчин, ферм админ', 'Админ cannot make an Админ');
select t.err(format($$select admin_update_profile(%L, null, null, 'super_admin')$$, :'HA'), 'малчин, ферм админ', 'Админ cannot make a super admin');
select t.err(format($$select admin_update_profile(%L, null, null, null, %L)$$, :'HA', :'f12'), 'өөрийн үүсгэсэн', 'Админ cannot move a user to a farm that is not his');
select t.err(format($$select admin_update_profile(%L, 'x')$$, :'H12'), 'засах эрхгүй', 'Админ cannot edit a user of another farm');
select t.err(format($$select admin_update_profile(%L, 'x')$$, :'ADM'), 'засах эрхгүй', 'Админ cannot edit himself through this');

-- ================= Админ Б sees none of it =================
select t.as_(:'ADM2');
select t.ok((select count(*) from farms) = 0 and (select count(*) from profiles) = 1, 'another Админ sees nothing of Админ А');
select t.err(format($$select admin_update_farm(%L, 'ADM-1', 'x', null, null, null, null)$$, :'fa'), 'засах эрхгүй', 'another Админ cannot edit it');

-- ================= herder of the Админ's farm registers ANY new tag =================
select t.as_(:'HA');
select t.ok((select reason from tag_registration_info(:'t12')) = 'ok', 'herder: a FERM-12 tag can be registered (any new tag)');
select t.ok((select farm_code from tag_registration_info(:'t12')) = 'ADM-1', '… and the page names HIS farm');
select register_cattle(:'t12', 'female', 2022) as cow \gset
reset role;
select t.ok((select farm_id from cattle where id = :'cow') = :'fa', 'animal is in the herder''s farm');
select t.ok((select farm_id from tags where tag_code = :'t12') = :'fa' and (select status from tags where tag_code = :'t12') = 'assigned',
            'tag moved to the herder''s farm and is assigned');
select t.ok((select farm_id from audit_log where action = 'register_cattle' and entity_id = :'cow') = :'fa', 'history row on the new farm');

set role authenticated;
select t.as_(:'ADM');
select t.ok((select count(*) from cattle) = 1 and (select count(*) from tags) = 1, 'Админ now sees the animal and its tag');
select t.ok((select count(*) from admin_tag_list) = 1, 'Админ: admin_tag_list shows it');
select t.as_(:'FA12');
select t.ok((select count(*) from cattle where id = :'cow') = 0, 'FERM-12 farm admin no longer sees it');
select t.as_(:'ADM');
select t.err(format($$select register_cattle(%L, 'male', 2020)$$, :'t07'), 'малчин эсвэл ферм админ', 'Админ himself cannot register an animal');
select t.ok((select reason from tag_registration_info(:'t07')) = 'no_farm', '… registration page says no_farm');
select t.err(format($$insert into milk_yield (farm_id, cattle_id, liters) values (%L, %L, 5)$$, :'fa', :'cow'), 'row-level security', 'Админ cannot add milk');

-- ================= pause a tag =================
select t.as_(:'HA');
select t.ok((select tag_code from public_tag_lookup(:'t12')) = :'t12', 'before pause: tap page finds the animal');
reset role;
-- Telegram links, to see who is told
insert into app_secrets (name, value) values ('telegram_token', 'TEST') on conflict (name) do update set value = 'TEST';
insert into telegram_links (profile_id, chat_id) values (:'HA', 111), (:'ADM', 222), (:'ADM2', 333), (:'FA12', 444);
delete from net.calls;
set role authenticated;
select t.as_(:'SUPER');
select t.ok((select admin_pause_tags(array[:'t12', :'t07'], true, 'шалгалт')) = 2, 'super admin pauses 2 tags');
select t.ok((select admin_pause_tags(array[:'t12'], true)) = 0, 'pausing again changes nothing');
reset role;
select t.ok((select string_agg((body->>'chat_id'), ',' order by body->>'chat_id') from net.calls) = '111,222',
            'Telegram on pause: the owner (111) and his farm''s Админ (222) only');
select string_agg((body->>'chat_id') || ': ' || (body->>'text'), E'\n') from net.calls;
set role anon;
select t.as_(null);
select t.ok(public_tag_state(:'t12') = 'paused', 'stranger: paused tag → paused');
select t.ok(public_tag_state(:'t07') = 'paused', 'stranger: paused blank tag → paused');
select t.ok((select count(*) from public_tag_lookup(:'t12')) = 0, 'stranger: lookup shows nothing');
select t.ok(record_public_scan(:'t12', 47.9, 106.9, 10, 'test') is null, 'stranger: tap is not saved');
select t.ok(public_tag_state(:'c12') is null, 'a normal registered tag: state stays empty');
select t.ok((select count(*) from public_tag_lookup(:'c12')) = 1, 'a normal registered tag still shows');
set role authenticated;
select t.as_(:'HA');
select t.ok((select reason from tag_registration_info(:'t07')) = 'paused', 'herder: paused blank tag → reason paused');
select t.err(format($$select register_cattle(%L, 'male', 2020)$$, :'t07'), 'түр зогсоогдсон', 'herder cannot register a paused tag');
select t.err(format($$insert into milk_yield (farm_id, cattle_id, liters, recorded_by) values (%L, %L, 5, %L)$$, :'fa', :'cow', :'HA'),
             'түр зогсоогдсон', 'herder cannot add milk to a paused animal');
select t.err(format($$insert into scan_events (client_uuid, scanned_at, farm_id, cattle_id, tag_id, scanned_by) values (gen_random_uuid(), now(), %L, %L, (select tag_id from cattle where id = %L), %L)$$, :'fa', :'cow', :'cow', :'HA'),
             'түр зогсоогдсон', 'herder app scan is refused');
select t.err(format($$select report_lost(%L, 'x')$$, :'cow'), 'түр зогсоогдсон', 'herder cannot mark the animal lost');
select t.err(format($$select set_contact_phone(%L, '99001122', true)$$, :'cow'), 'түр зогсоогдсон', 'herder cannot change its phone');
select t.err(format($$select log_feeding(%L, 'hay', null)$$, :'cow'), 'түр зогсоогдсон', 'herder cannot log feeding');
select t.ok((select count(*) from cattle where id = :'cow') = 1, 'herder still sees the animal (history kept)');
select t.as_(:'SUPER');
select t.ok((select admin_pause_tags(array[:'t12', :'t07'], false)) = 2, 'super admin resumes');
select t.as_(:'HA');
select t.ok((select count(*) from public_tag_lookup(:'t12')) = 1, 'after resume: tap page shows it again');
insert into milk_yield (farm_id, cattle_id, liters, recorded_by) values (:'fa', :'cow', 5, :'HA');
select t.ok(true, 'after resume: herder adds milk');
select t.ok((select reason from tag_registration_info(:'t07')) = 'ok', 'after resume: blank tag registrable');

-- ================= pause / resume the whole farm =================
reset role;
update profiles set status = 'disabled' where id = :'HA2';     -- switched off before the pause
delete from net.calls;
set role authenticated;
select t.as_(:'SUPER');
select archive_farm(:'fa', 'шалгалт');
select archive_farm(:'fa2', 'шалгалт');
reset role;
select t.ok((select string_agg(body->>'chat_id', ',' order by body->>'chat_id') from net.calls) = '111,222,222',
            'farm pause: herder + Админ told (once per farm)');
select t.ok((select status from profiles where id = :'HA') = 'disabled', 'farm pause switches its people off');
set role anon; select t.as_(null);
select t.ok(public_tag_state(:'t12') = 'paused', 'paused farm: its tag says paused');
set role authenticated; select t.as_(:'ADM');
select t.ok((select count(*) from cattle) = 1, 'Админ still sees the paused farm''s animal');
select t.as_(:'SUPER');
select restore_farm(:'fa');
select restore_farm(:'fa2');
reset role;
select t.ok((select status from profiles where id = :'HA') = 'active', 'resume switches the herder back on');
select t.ok((select status from profiles where id = :'HA2') = 'disabled', 'resume leaves the one who was off before off');
set role anon; select t.as_(null);
select t.ok(public_tag_state(:'t12') is null and (select count(*) from public_tag_lookup(:'t12')) = 1, 'resumed farm: tag works');

-- ================= storage: photos of his farms only =================
reset role;
insert into storage.objects (bucket_id, name) values
  ('cattle-photos', 'farm-' || :'fa' || '/cow-' || :'cow' || '/a.jpg'),
  ('cattle-photos', 'farm-' || :'f12' || '/cow-x/b.jpg'),
  ('cattle-public', 'farm-' || :'f12' || '/cow-' || :'cow' || '/old.jpg');
set role authenticated; select t.as_(:'ADM');
select t.ok((select count(*) from storage.objects) = 2, 'Админ: his farm''s photo + the animal''s photo from before it moved');
select t.as_(:'ADM2');
select t.ok((select count(*) from storage.objects) = 0, 'other Админ: no photos');

-- ================= lost alert reaches the Админ =================
reset role;
delete from net.calls;
select tg_alert_lost_scan(:'cow', 47.9, 106.9, 5, now(), null);
select t.ok((select string_agg(body->>'chat_id', ',' order by body->>'chat_id') from net.calls) like '%222%', 'lost alert: Админ told');
select t.ok((select string_agg(body->>'chat_id', ',' order by body->>'chat_id') from net.calls) not like '%333%', 'lost alert: other Админ not told');

-- ================= super admin: hand a farm to an Админ =================
set role authenticated; select t.as_(:'SUPER');
select admin_set_farm_owner(:'f03', :'ADM2');
select t.as_(:'ADM2');
select t.ok((select count(*) from farms) = 1, 'farm handed to Админ Б shows up for him');
select t.as_(:'SUPER');
select t.err(format($$select admin_set_farm_owner(%L, %L)$$, :'f03', :'H12'), 'Админ эрхтэй биш', 'only an Админ can be given a farm');
select admin_update_profile(:'ADM2', null, null, 'herder', :'f12');
select t.ok((select farm_id from profiles where id = :'ADM2') = :'f12', 'super admin can still change any role');
select admin_update_profile(:'ADM2', null, null, 'admin');
reset role;
select t.ok((select farm_id from profiles where id = :'ADM2') is null, 'making someone Админ clears his farm');

-- ================= delete farms =================
set role authenticated; select t.as_(:'SUPER');
-- FERM-03: an empty farm with a batch (the error the owner saw)
select delete_farm(:'f03', false);
select t.ok((select count(*) from farms where id = :'f03') = 0, 'empty farm with a batch deletes (no FK error)');
-- FERM-07: a FERM-12 herder takes one of its tags first, then it is deleted
select t.as_(:'H12');
select register_cattle(:'t07b', 'male', 2021) as cow2 \gset
select t.as_(:'SUPER');
select t.err(format($$select delete_farm(%L, false)$$, :'f07'), 'pass force', 'farm with users/tags: asks for force first');
select delete_farm(:'f07', true) as res \gset
\echo delete FERM-07 → :res
reset role;
select t.ok((select count(*) from farms where id = :'f07') = 0, 'FERM-07 gone');
select t.ok((select farm_id from tags where tag_code = :'t07b') = :'f12', 'its tag on the FERM-12 animal stays');
select t.ok((select farm_id from tag_batches where id = (select batch_id from tags where tag_code = :'t07b')) = :'f12',
            'its batch moved to FERM-12 (still holds that tag)');
select t.ok((select count(*) from tags where tag_code = :'t07') = 0, 'its unused tags are deleted');
select t.ok((select count(*) from profiles where id = :'FA07' and not (status = 'disabled' and farm_id is null)) = 0,
            'its farm admin: deleted, or switched off without a farm if he has history');
select t.ok((select count(*) from audit_log where action = 'farm_delete' and entity_id = :'f07') = 1, 'delete is in the history');
-- the Админ's farm, with an animal, milk, photo, scans
set role authenticated; select t.as_(:'SUPER');
select delete_farm(:'fa', true) as res2 \gset
\echo delete ADM-1 → :res2
reset role;
select t.ok((select count(*) from cattle where id = :'cow') = 0 and (select count(*) from milk_yield where cattle_id = :'cow') = 0,
            'its animal and milk are gone');
select t.ok((select count(*) from profiles where id = :'HA') = 1 and (select status from profiles where id = :'HA') = 'disabled',
            'its herder (author of history) is switched off');
select t.ok((select count(*) from profiles where id = :'ADM') = 1, 'the Админ himself stays');
select t.ok((select count(*) from audit_log where entity_id = :'cow') >= 1, 'history rows are kept');

-- delete_profile: a user with history is switched off
set role authenticated; select t.as_(:'SUPER');
select t.ok(delete_profile(:'H12', true) = 'disabled', 'delete_profile: user with history → disabled');
select t.ok(delete_profile(:'ADM2') in ('deleted', 'disabled'), 'delete_profile: an Админ');

-- ================= anon cannot call the new helpers =================
set role anon; select t.as_(null);
select t.err($$select admin_farm_ids()$$, 'permission denied', 'anon: admin_farm_ids refused');
select t.err($$select admin_pause_tags(array['x'], true)$$, 'permission denied', 'anon: admin_pause_tags refused');
select t.err($$select notify_farm(null, 'x')$$, 'permission denied', 'anon: notify_farm refused');
set role authenticated; select t.as_(:'HA');
select t.err($$select notify_farm(null, 'x')$$, 'permission denied', 'signed in: notify_farm refused');

reset role;
\echo ALL V49 TESTS PASSED
rollback;
