-- Tests for schema_v57 (our BLE listener network) on the local replay DB.
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
grant execute on all functions in schema t to public;

select id as herder, farm_id as farm from profiles where role = 'herder' and farm_id is not null order by id limit 1 \gset
select id as other from profiles where status = 'active' and id <> :'herder' and role = 'herder' order by id desc limit 1 \gset
select id as boss from profiles where role = 'super_admin' order by id limit 1 \gset
insert into app_secrets (name, value) values ('telegram_token', 'TEST') on conflict (name) do update set value = 'TEST';
delete from telegram_links where chat_id in (901, 900);
insert into telegram_links (profile_id, chat_id) values (:'herder', 901) on conflict do nothing;
insert into telegram_links (profile_id, chat_id) values (:'boss', 900) on conflict do nothing;

set role authenticated; select t.as_(:'herder');
select register_horse('female', 2019, 'galshar', null, 'хээр') as h1 \gset
select set_ble_tag(:'h1', 'YT-H00001');
reset role;

-- ---------- a phone hears it (another herder: the crowd) ----------
set role authenticated; select t.as_(:'other');
select ble_report(47.5, 106.5, 15, '[{"name":"yt-h00001","rssi":-70,"battery":88},{"name":"YT-H99999"},{"name":"someone else"}]') as n1 \gset
select ble_report(47.6, 106.6, 15, '[{"name":"YT-H00001","rssi":-60}]') as n2 \gset
select t.ok((select count(*) from ble_sightings where cattle_id = :'h1') = 0, 'the reporter does not see another farm''s horse''s sightings');
reset role;
select t.ok(:n1 = 1, 'one of three names is ours (any spelling); the rest ignored');
select t.ok(:n2 = 0, 'the same phone again within 10 minutes: not saved twice');
select t.ok((select source = 'app' and reporter = :'other' and lat = 47.5 and rssi = -70 and battery = 88
               from ble_sightings where cattle_id = :'h1'), 'sighting saved with the phone''s place, signal and battery');
select t.ok((select ble_battery = 88 and ble_heard_at > now() - interval '1 minute' from cattle where id = :'h1'),
            'the horse shows the tag''s battery and when it was last heard');
set role authenticated; select t.as_(:'herder');
select t.ok((select last_lat = 47.5 from cattle_dashboard where id = :'h1'), 'the owner''s "last seen" moved there (all_scans)');
select t.ok((select count(*) from ble_sightings where cattle_id = :'h1') = 1, 'the owner sees the sighting');
reset role;

-- ---------- a box at a well ----------
set role authenticated; select t.as_(:'herder');
select ble_gateway_create('Хойд худаг', 46.9, 105.9) as k1 \gset
select ble_gateway_create('Өвөлжөө', 46.8, 105.8) as k2 \gset
select t.ok(:'k1' ~ '^ytg_[0-9a-f]{64}$', 'a box gets a long secret key, shown once');
select t.err('select key_hash from ble_gateways', 'permission denied', 'the key''s hash cannot be read back');
select t.ok((select count(*) from ble_gateways where name = 'Хойд худаг') = 1, 'the farm sees its boxes');
reset role;
set role anon; select t.as_(null);
select ble_gateway_report(:'k1', '[{"name":"YT-H00001","rssi":-80,"seen_at":"2099-01-01T00:00:00Z"}]') as g1 \gset
select t.err($q$select ble_gateway_report('ytg_wrong', '[]')$q$, 'Unknown listener key', 'a wrong key refused');
select t.err($q$select ble_report(1, 1, 1, '[]')$q$, 'permission denied', 'visitors cannot report as a phone');
reset role;
select t.ok(:g1 = 1 and (select source = 'gateway' and lat = 46.9 and scanned_at <= now() + interval '1 minute'
                         from ble_sightings where cattle_id = :'h1' and gateway_id is not null),
            'box report: saved at the box''s place; a time in the future becomes now');
select t.ok((select last_report_at is not null from ble_gateways where name = 'Хойд худаг'), 'the box''s last report is shown');

-- ---------- a lost horse is heard ----------
set role authenticated; select t.as_(:'herder');
select report_lost(:'h1', 'хулгай', true, true);
reset role;
set role anon;
select ble_gateway_report(:'k2', '[{"name":"YT-H00001","rssi":-75}]') as g2 \gset
reset role;
select t.ok((select count(*) from notify_log where cattle_id = :'h1' and kind = 'horse_ble' and chat_id in (900, 901)) = 2,
            'a stolen horse''s tag heard: the owner and the super admin get an alert');

-- ---------- checks ----------
select t.err(format('select ble_ingest(%L, null, null, 1, 1, 1, %L)', 'app', (select jsonb_agg(jsonb_build_object('name', 'x' || g)) from generate_series(1, 51) g)),
             '50-аас ихгүй', 'more than 50 at once refused');
set role authenticated; select t.as_(:'other');
select count(ble_report(1, 1, 1, '[]')) from generate_series(1, 118);
select t.err($q$select ble_report(1, 1, 1, '[]')$q$, 'Хэт олон', 'a phone''s 121st report in an hour refused');
select t.err(format('select ble_gateway_delete(%L)', (select id from ble_gateways where name = 'Хойд худаг')), 'эрхгүй',
             'another herder cannot remove a box he did not add');
select t.as_(:'herder');
select ble_gateway_delete((select id from ble_gateways where name = 'Хойд худаг'));
reset role;
select t.ok((select count(*) from ble_sightings where cattle_id = :'h1' and source = 'gateway') = 2,
            'a removed box: its old sightings stay (box link cleared)');
select t.ok(not has_function_privilege('anon', 'public.ble_ingest(text,uuid,uuid,double precision,double precision,double precision,jsonb)', 'execute')
            and not has_function_privilege('authenticated', 'public.ble_limit(text,integer)', 'execute')
            and not has_function_privilege('anon', 'public.ble_gateway_create(text,double precision,double precision,uuid)', 'execute')
            and has_function_privilege('anon', 'public.ble_gateway_report(text,jsonb)', 'execute'),
            'only the box report is open to visitors (with its key); helpers closed');

rollback;
