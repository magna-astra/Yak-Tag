-- Tests for schema_v56 (horse theft protection + BLE) on the local replay DB.
-- One transaction, rolled back.
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
create function t.as_(u text) returns void language sql as $$
  select set_config('request.jwt.claims',
    case when u is null then '' else json_build_object('sub', u, 'role', 'authenticated')::text end, false)
$$;
create function t.ip(a text) returns void language sql as $$
  select set_config('request.headers', json_build_object('x-forwarded-for', a)::text, false)
$$;
grant execute on all functions in schema t to public;

select id as herder, farm_id as farm from profiles where role = 'herder' and farm_id is not null order by id limit 1 \gset
select id as herder2 from profiles where role = 'herder' and farm_id = :'farm' and id <> :'herder' order by id limit 1 \gset
select id as boss from profiles where role = 'super_admin' order by id limit 1 \gset
select tag_code as blank from tags t where status = 'blank' and farm_id = :'farm'
   and not exists (select 1 from cattle c where c.tag_id = t.id) order by tag_code limit 1 \gset
select tag_code as cowtag from cattle where species is distinct from 'horse' and tag_code is not null order by tag_code limit 1 \gset

insert into app_secrets (name, value) values ('telegram_token', 'TEST') on conflict (name) do update set value = 'TEST';
delete from telegram_links where chat_id in (901, 900);
insert into telegram_links (profile_id, chat_id) values (:'herder', 901) on conflict do nothing;
insert into telegram_links (profile_id, chat_id) values (:'boss', 900) on conflict do nothing;

-- two horses: no tag (chip + MGL), and with a YAK-TAG tag
set role authenticated; select t.as_(:'herder');
select register_horse('female', 2020, 'galshar', null, 'хээр', false, array['халзан'], '956000012345678', 'MGL0123456789') as h1 \gset
select register_horse('male', 2019, 'tes', null, 'хул', false, '{}', null, null, null, null, null, :'blank') as h2 \gset
reset role;
update cattle set public_photo_path = 'farm-x/cow-y/profile-1.jpg', contact_phone = '99112233' where id = :'h1';

-- ---------- a normal horse, checked by a stranger ----------
set role anon; select t.as_(null); select t.ip('10.5.0.1');
select public_horse_check('956 000 012 345 678', 47.9, 106.9, 12) as r1 \gset
reset role;
select t.ok((:'r1'::jsonb)->>'found' = 'true' and (:'r1'::jsonb)->>'status' = 'ok' and (:'r1'::jsonb)->>'kind' = 'chip'
            and (:'r1'::jsonb)->>'colour' = 'хээр' and (:'r1'::jsonb)->>'photo_path' is not null
            and (:'r1'::jsonb)->>'phone' = '99112233',
            'chip with spaces: registered, not lost, photo + зүс + call button');
select t.ok((:'r1'::jsonb)->>'brand_path' is null and (:'r1'::jsonb)->>'lost_note' is null
            and not ((:'r1'::jsonb) ? 'owner_name') and not ((:'r1'::jsonb) ? 'full_name'),
            'a normal horse: no brand photo, no note, never the owner''s name');
select t.ok((select count(*) from notify_log where cattle_id = :'h1' and kind = 'horse_check' and chat_id = 901) = 1
            and (select count(*) from notify_log where cattle_id = :'h1' and chat_id = 900) = 0,
            'the owner gets "your horse was checked" (and only the owner)');
select t.ok((select lat = 47.9 and found and not was_lost and query_kind = 'chip' from horse_checks where cattle_id = :'h1'),
            'the check is kept with its place');

set role anon; select t.ip('10.5.0.2');
select public_horse_check('mgl-0123456789') as r2 \gset
select public_horse_check(lower(replace(:'blank', '-', ''))) as r3 \gset
select public_horse_check('956000099999999') as r4 \gset
select t.err($q$select public_horse_check('hello')$q$, 'Чип \(15 оронтой\)', 'nonsense refused with a hint');
select public_horse_check(:'cowtag') as r5 \gset
reset role;
select t.ok((:'r2'::jsonb)->>'kind' = 'national_id' and (:'r2'::jsonb)->>'found' = 'true', 'national number (small letters, dash) finds it');
select t.ok((:'r3'::jsonb)->>'kind' = 'tag' and (:'r3'::jsonb)->>'ref' = :'h2', 'tag number written any way finds the tagged horse');
select t.ok((:'r4'::jsonb)->>'found' = 'false', 'unknown chip: not found');
select t.ok((:'r5'::jsonb)->>'found' = 'false', 'a cow''s tag: not a horse, not found here');
select t.ok((select count(*) from notify_log where cattle_id = :'h1' and kind = 'horse_check' and chat_id = 901) = 1,
            'a second check within 10 minutes: no second message');

-- ---------- per-visitor limit ----------
set role anon; select t.ip('10.5.0.3');
select count(public_horse_check('956000099999998')) from generate_series(1, 30);
select t.err($q$select public_horse_check('956000099999998')$q$, 'Хэт олон', 'the 31st check in an hour refused');
reset role;

-- ---------- stolen ----------
set role authenticated; select t.as_(:'herder');
select report_lost(:'h1', 'Хэнтий, Галшар сум, 10/20', true, true);
select set_public_brand(:'h1', 'farm-' || :'farm' || '/cow-' || :'h1' || '/brand-1.jpg');
select t.err(format('select set_public_brand(%L, %L)', :'h1', 'farm-other/cow-x/brand.jpg'), 'Not allowed', 'brand path outside the horse''s folder refused');
reset role;
select t.ok((select status = 'stolen' and lost_public and reported_lost_at is not null from cattle where id = :'h1'), 'reported stolen, shown in the list');

set role anon; select t.ip('10.5.0.4');
select public_horse_check('956000012345678', 46.1, 105.2, 30) as r6 \gset
select public_lost_horses() as l1 \gset
select public_lost_horses('зээрд') as l2 \gset
reset role;
select t.ok((:'r6'::jsonb)->>'status' = 'stolen' and (:'r6'::jsonb)->>'brand_path' like '%brand-1.jpg'
            and (:'r6'::jsonb)->>'lost_note' like 'Хэнтий%', 'a stolen horse: warning, brand photo, note');
select t.ok((select count(*) from notify_log where cattle_id = :'h1' and kind = 'horse_lost_check' and chat_id in (900, 901)) = 2,
            'checking a stolen horse alerts the owner and the super admin');
select t.ok(jsonb_array_length(:'l1'::jsonb) = 1 and (:'l1'::jsonb)->0->>'ref' = :'h1'
            and (:'l1'::jsonb)->0->>'brand_path' is not null, 'the public list shows it, with the brand');
select t.ok(jsonb_array_length(:'l2'::jsonb) = 0, 'filtered by another зүс: not listed');

-- lost but NOT public: no list, no brand / note on a check
set role authenticated; select t.as_(:'herder');
select report_lost(:'h2', 'ойр орчим', false, false);
reset role;
set role anon; select t.ip('10.5.0.5');
select public_lost_horses() as l3 \gset
select public_horse_check(:'blank') as r7 \gset
reset role;
select t.ok(jsonb_array_length(:'l3'::jsonb) = 1, 'an owner who said "not public": not in the list');
select t.ok((:'r7'::jsonb)->>'status' = 'lost' and (:'r7'::jsonb)->>'brand_path' is null and (:'r7'::jsonb)->>'lost_note' is null,
            'checking it still warns "lost", without brand or note');

-- ---------- "I saw this horse" ----------
set role anon; select t.ip('10.5.0.6');
select public_horse_seen(:'h1', 45.5, 104.4, 8, 'Голын эрэг дээр', '+976 9911 2233') as s1 \gset
select t.err(format('select public_horse_seen(%L, null, null, null, null, %L)', :'h1', 'call me'), 'Утасны дугаар буруу', 'a wrong phone refused');
reset role;
select t.ok(:'s1'::boolean and (select seen and note = 'Голын эрэг дээр' and finder_phone = '+976 9911 2233' and lat = 45.5
                                  from horse_checks where cattle_id = :'h1' and seen),
            '"I saw it": kept with place, note and phone');
select t.ok((select count(*) from notify_log where cattle_id = :'h1' and kind = 'horse_seen') = 2, '…and the owner + super admin are told');

-- ---------- found ----------
set role authenticated; select t.as_(:'herder');
select report_found(:'h1');
select report_lost(p_cattle_id => :'h2', p_note => 'хоёр аргументтай');     -- the old call still works
reset role;
set role anon; select t.ip('10.5.0.7');
select public_lost_horses() as l4 \gset
select public_horse_seen(:'h1') as s2 \gset
reset role;
select t.ok(not (:'l4'::jsonb) @> jsonb_build_array(jsonb_build_object('ref', :'h1'))
            and (:'l4'::jsonb) @> jsonb_build_array(jsonb_build_object('ref', :'h2')),
            'found: off the list; h2 re-reported the old way is public by default');
select t.ok(not :'s2'::boolean, '"I saw it" for a horse that is not lost: refused (false)');
select t.ok((select status = 'lost' and lost_public from cattle where id = :'h2'), 'old two-argument report_lost: lost, public by default');

-- ---------- the owner sees the checks; others don't ----------
set role authenticated; select t.as_(:'herder');
select t.ok((select count(*) from horse_checks where cattle_id = :'h1') >= 4, 'the owner sees his horse''s checks');
select t.as_(:'herder2');
select t.ok((select count(*) from horse_checks where cattle_id = :'h1') = 0, 'another herder does not');
reset role;
set role anon;
select t.err('select count(*) from horse_checks', 'permission denied', 'visitors cannot read checks');
reset role;

-- ---------- BLE ----------
set role authenticated; select t.as_(:'herder');
select set_ble_tag(:'h1', ' YT-H001 ');
select t.err(format('select set_ble_tag(%L, %L)', :'h2', 'yt-h001'), 'өөр малд', 'the same beacon on two animals refused');
select t.as_(:'herder2');
select t.err(format('select set_ble_tag(%L, %L)', :'h1', 'YT-H009'), 'эрхгүй', 'another herder cannot link a beacon');
reset role;
select t.ok((select ble_name = 'YT-H001' from cattle where id = :'h1'), 'beacon linked (spaces trimmed)');
insert into scan_events (client_uuid, scanned_at, farm_id, cattle_id, scanned_by, method, lat, lng)
  values (gen_random_uuid(), now(), :'farm', :'h1', :'herder', 'ble', 47.0, 106.0);
select t.ok(true, 'a BLE encounter is a scan (method ble)');
select t.err(format('insert into scan_events (client_uuid, scanned_at, farm_id, cattle_id, scanned_by, method) values (gen_random_uuid(), now(), %L, %L, %L, %L)', :'farm', :'h2', :'herder', 'wifi'),
             'scan_events_method_check', 'unknown method still refused');

-- ---------- permissions ----------
select t.ok(has_function_privilege('anon', 'public.public_horse_check(text,double precision,double precision,double precision)', 'execute')
            and has_function_privilege('anon', 'public.public_horse_seen(uuid,double precision,double precision,double precision,text,text)', 'execute')
            and has_function_privilege('anon', 'public.public_lost_horses(text,text,integer,integer)', 'execute'),
            'visitors can check, report "seen" and see the list');
select t.ok(not has_function_privilege('anon', 'public.report_lost(uuid,text,boolean,boolean)', 'execute')
            and not has_function_privilege('anon', 'public.set_ble_tag(uuid,text)', 'execute')
            and not has_function_privilege('anon', 'public.set_public_brand(uuid,text)', 'execute')
            and not has_function_privilege('authenticated', 'public.tg_alert_horse(uuid,text,double precision,double precision,double precision,text,text)', 'execute')
            and not has_function_privilege('authenticated', 'public.horse_check_limit(text,integer)', 'execute')
            and not has_function_privilege('anon', 'public.public_horse_card(public.cattle,boolean)', 'execute'),
            'everything else is closed to visitors; helpers to everyone');

rollback;
