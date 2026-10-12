-- Tests for schema_v51 on the local replay DB. One transaction, rolled back.
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

select t.ok((select count(*) from pg_proc where proname = 'record_public_scan') = 1, 'exactly one record_public_scan (no ambiguous overload)');
select t.ok(has_function_privilege('anon', 'public.record_public_scan(text,numeric,numeric,numeric,text,uuid,timestamptz,bigint)', 'execute'),
            'visitors can still call it');

select id as cow, owner_id as own, tag_code as tag from cattle where status = 'active' and tag_code is not null order by tag_code limit 1 \gset
delete from public_scans where cattle_id = :'cow';
insert into app_secrets (name, value) values ('telegram_token', 'TEST') on conflict (name) do update set value = 'TEST';
insert into telegram_links (profile_id, chat_id) values (:'own', 901) on conflict do nothing;
insert into telegram_links (profile_id, chat_id) values ('00000000-0000-0000-0000-000000000001', 900) on conflict do nothing;

-- ---------- tap time ----------
set role anon; select t.as_(null);
select t.ip('10.1.1.1');
select record_public_scan(:'tag', 47.1, 101.1, 5, 'old page', gen_random_uuid(), now() - interval '2 hours') as s1 \gset
select t.ip('10.1.1.2');
-- phone clock 2 days slow, tap was 3 h ago (age measured on the phone)
select record_public_scan(:'tag', 47.2, 101.2, 5, 'new page', gen_random_uuid(), now() - interval '2 days 3 hours', 3 * 3600000) as s2 \gset
select t.ip('10.1.1.3');
select record_public_scan(:'tag', 47.3, 101.3, 5, 'bad age', gen_random_uuid(), now() - interval '1 hour', -5) as s3 \gset
reset role;
select t.ok(abs(extract(epoch from (select scanned_at from public_scans where id = :'s1') - (now() - interval '2 hours'))) < 2,
            'a page without the age (already on phones): the phone''s time is kept');
select t.ok(abs(extract(epoch from (select scanned_at from public_scans where id = :'s2') - (now() - interval '3 hours'))) < 2,
            'phone clock 2 days wrong, tap 3 h ago: stored as 3 h ago (age wins)');
select t.ok(abs(extract(epoch from (select scanned_at from public_scans where id = :'s3') - (now() - interval '1 hour'))) < 2,
            'impossible age ignored: the phone''s time is used');
select t.ok((select was_offline from public_scans where id = :'s2'), 'late tap marked as sent later (offline)');

-- ---------- lost alert says "arrived late" ----------
update cattle set status = 'lost', reported_lost_at = now() - interval '1 day' where id = :'cow';
delete from public_scans where cattle_id = :'cow';
delete from notify_log where cattle_id = :'cow';
delete from net.calls;
set role anon; select t.as_(null); select t.ip('10.2.2.2');
select record_public_scan(:'tag', 47.452137, 101.621344, 9, 'late', gen_random_uuid(), null, 3 * 3600000) is not null;
reset role;
select t.ok((select body->>'text' from net.calls where body->>'chat_id' = '901') like '%⏱ Сүлжээгүй үед уншуулсан%',
            'late tap: the owner''s alert says it was tapped with no signal');
select body->>'text' from net.calls where body->>'chat_id' = '901';
delete from notify_log where cattle_id = :'cow';
delete from net.calls;
set role anon; select t.ip('10.2.2.3');
select record_public_scan(:'tag', 47.5, 101.5, 9, 'fresh', gen_random_uuid(), now(), 1500) is not null;
reset role;
select t.ok((select body->>'text' from net.calls where body->>'chat_id' = '901') not like '%⏱%', 'fresh tap: no "late" line');

-- ---------- registration limit ----------
select id as h from profiles where role = 'herder' and status = 'active' and farm_id is not null order by id limit 1 \gset
delete from net.calls;
set role authenticated; select t.as_(:'h');
do $$ declare tg text; n int := 0; begin
  for tg in select tag_code from tags where status in ('blank','written','recycled') and paused_at is null
              and not exists (select 1 from cattle c where c.tag_id = tags.id) order by tag_code limit 60 loop
    perform register_cattle(tg, 'female', 2021); n := n + 1;
  end loop;
  if n < 60 then raise exception 'FAIL: only % free tags for the test', n; end if;
end $$;
select t.ok(true, '60 registrations in an hour: allowed');
select t.err($$select register_cattle((select tag_code from tags where status in ('blank','written','recycled') and paused_at is null
               and not exists (select 1 from cattle c where c.tag_id = tags.id) order by tag_code limit 1), 'male', 2020)$$,
             '60-аас олон', 'the 61st in the hour is refused');
reset role;
select t.ok((select count(*) from net.calls where body->>'chat_id' = '900' and body->>'text' like '%50 мал бүртгэлээ%') = 1,
            'the super admin got ONE warning at 50');
set role authenticated; select t.as_('00000000-0000-0000-0000-000000000001');
select t.ok((select reason from tag_registration_info('ZZ-NONE')) = 'not_found', 'super admin unaffected (sanity)');

-- ---------- order form: 100 per day ----------
reset role;
insert into order_requests (name, phone, qty, created_at)
  select 'Test ' || g, '99000000', 1, now() - interval '3 hours' from generate_series(1, 100) g;
set role anon; select t.as_(null); select t.ip('10.3.3.3');
select t.err($$select submit_order('Бат', '99112233', 10)$$, 'хүсэлт их', '101st order of the day is refused');
reset role;
delete from order_requests where name like 'Test %';
set role anon; select t.ip('10.3.3.4');
select t.ok(submit_order('Бат', '99112233', 10), 'a normal day: the order goes through');

reset role;
\echo ALL V51 TESTS PASSED
rollback;
