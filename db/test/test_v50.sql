-- Tests for schema_v50 (tag stock, "Фермгүй") on the local replay DB.
-- One transaction, rolled back at the end: the DB stays as it was.
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

\set SUPER  '00000000-0000-0000-0000-000000000001'
\set FA12   '00000000-0000-0000-0000-000000000002'
\set FA07   '00000000-0000-0000-0000-000000000003'
\set H12    '00000000-0000-0000-0000-000000000004'

select id as f12 from farms where code = 'FERM-12' \gset
select id as f07 from farms where code = 'FERM-07' \gset
select tag_code as a from tags where farm_id = :'f12' and status in ('blank','written','recycled')
  and not exists (select 1 from cattle c where c.tag_id = tags.id) order by tag_code limit 1 \gset
select tag_code as b from tags where farm_id = :'f12' and status in ('blank','written','recycled')
  and not exists (select 1 from cattle c where c.tag_id = tags.id) order by tag_code offset 1 limit 1 \gset
select tag_code as c from tags where farm_id = :'f12' and status in ('blank','written','recycled')
  and not exists (select 1 from cattle c where c.tag_id = tags.id) order by tag_code offset 2 limit 1 \gset
select tag_code as d from tags where farm_id = :'f12' and status in ('blank','written','recycled')
  and not exists (select 1 from cattle c where c.tag_id = tags.id) order by tag_code offset 3 limit 1 \gset
select tag_code as on_cow, id as cow12 from cattle where farm_id = :'f12' order by tag_code limit 1 \gset
select tag_code as t07 from tags where farm_id = :'f07' order by tag_code limit 1 \gset

-- ================= move tags to the stock =================
set role authenticated; select t.as_(:'SUPER');
select t.ok((select (admin_assign_tags(array[:'a', :'b', :'c', :'d', :'on_cow'], null))->>'moved') = '4',
            'super admin moves 4 unused tags to the stock (the one on an animal is skipped)');
reset role;
select t.ok((select count(*) from tags where tag_code in (:'a', :'b', :'c', :'d') and farm_id is null) = 4, '… they have no farm now');
select t.ok((select farm_id from tags where tag_code = :'on_cow') = :'f12', '… the tag on an animal stays');
set role authenticated; select t.as_(:'SUPER');
select t.ok((select count(*) from admin_tag_list where farm_id is null) = 4, 'super admin: stock tags show in the tag list');
select t.as_(:'FA12');
select t.ok((select count(*) from tags where farm_id is null) = 0, 'farm admin does not see the stock');
select t.ok((select count(*) from admin_tag_list where farm_id is null) = 0, 'farm admin: not in his tag list either');
select t.err(format($$select admin_assign_tags(array[%L], null)$$, :'a'), 'ерөнхий', 'farm admin cannot move tags');

-- ================= a stock tag works like any new tag =================
set role anon; select t.as_(null);
select t.ok(public_tag_state(:'a') = 'new', 'stranger: stock tag → "Шинэ таг"');
set role authenticated; select t.as_(:'H12');
select t.ok((select reason || '/' || farm_code from tag_registration_info(:'a')) = 'ok/FERM-12', 'herder: can register, page names his farm');
select register_cattle(:'a', 'female', 2023) as cow \gset
reset role;
select t.ok((select farm_id from cattle where id = :'cow') = :'f12' and (select farm_id from tags where tag_code = :'a') = :'f12'
            and (select status from tags where tag_code = :'a') = 'assigned', 'animal + tag are in the herder''s farm');
set role authenticated; select t.as_(:'FA07');
select register_cattle(:'b', 'male', 2022) as cow07 \gset
reset role;
select t.ok((select farm_id from tags where tag_code = :'b') = :'f07', 'a farm admin of another farm registers a stock tag → his farm');
set role authenticated; select t.as_(:'SUPER');
select t.ok((select reason from tag_registration_info(:'c')) = 'no_farm', 'super admin: a stock tag has no farm to register into');
select t.err(format($$select register_cattle(%L, 'male', 2020)$$, :'c'), 'Агуулахын', 'super admin cannot register on a stock tag');

-- ================= pause a stock tag =================
select admin_pause_tags(array[:'c'], true);
set role anon; select t.as_(null);
select t.ok(public_tag_state(:'c') = 'paused', 'paused stock tag → paused');
set role authenticated; select t.as_(:'SUPER');
select admin_pause_tags(array[:'c'], false);
set role anon; select t.as_(null);
select t.ok(public_tag_state(:'c') = 'new', 'resumed stock tag → new');

-- ================= new tag numbers straight into the stock =================
set role authenticated; select t.as_(:'SUPER');
select t.ok((select (admin_create_tags('YT', 900001, 900005, null))->>'created') = '5', 'create 5 tag numbers with no farm');
reset role;
select t.ok((select count(*) from tags where tag_code between 'YT-900001' and 'YT-900005' and farm_id is null) = 5
            and (select farm_id from tag_batches where prefix = 'YT' and range_start = 900001) is null, '… tags and their batch have no farm');
set role authenticated; select t.as_(:'SUPER');
select t.ok((select (admin_assign_tags(array['YT-900001'], :'f12'))->>'moved') = '1', 'move one of them to a farm');
select t.ok((select (admin_assign_tags(array['YT-900001'], null))->>'moved') = '1', '… and back to the stock');

-- ================= replace a lost tag with a stock tag =================
select t.as_(:'FA12');
select admin_replace_tag(:'cow12', :'d', 'lost', 'test');
reset role;
select t.ok((select tag_code from cattle where id = :'cow12') = :'d' and (select farm_id from tags where tag_code = :'d') = :'f12',
            'farm admin replaces a lost tag with a stock tag; it joins his farm');
set role authenticated; select t.as_(:'FA12');
select t.err(format($$select admin_replace_tag(%L, %L, 'lost', 'x')$$, :'cow12', :'t07'), 'өөр фермийнх', 'another farm''s tag is still refused');

-- ================= delete a farm: its tags go to the stock =================
select t.as_(:'SUPER');
select t.err(format($$select delete_farm(%L, false)$$, :'f07'), 'pass force', 'farm with animals/users: asks for force first');
select delete_farm(:'f07', true) as res \gset
\echo delete FERM-07 → :res
reset role;
select t.ok((select count(*) from farms where id = :'f07') = 0, 'FERM-07 deleted');
select t.ok((select count(*) from tags where tag_code = :'t07' and farm_id is null) = 1, 'its unused tag is in the stock, not deleted');
select t.ok((select status from tags where tag_code = :'b') = 'recycled' and (select farm_id from tags where tag_code = :'b') is null,
            'the tag of its deleted animal: stock, can carry a new animal');
select t.ok((select count(*) from tag_batches b where exists (select 1 from tags x where x.batch_id = b.id and x.tag_code = :'t07')) = 1,
            'its batch is kept (it holds tags)');
set role anon; select t.as_(null);
select t.ok(public_tag_state(:'b') = 'new', 'that tag is "new" again');
set role authenticated; select t.as_(:'H12');
select register_cattle(:'b', 'female', 2021);
reset role;
select t.ok((select farm_id from tags where tag_code = :'b') = :'f12', 'a herder registers it again → his farm');
-- a farm with only tags is deleted without the force question
set role authenticated; select t.as_(:'SUPER');
select create_farm('TEST-X', 'Туршилт', null, null) as fx \gset
select admin_assign_tags(array['YT-900002', 'YT-900003'], :'fx');
select delete_farm(:'fx', false);
reset role;
select t.ok((select count(*) from tags where tag_code in ('YT-900002', 'YT-900003') and farm_id is null) = 2,
            'farm with only tags: deleted directly, tags back in the stock');

reset role;
\echo ALL V50 TESTS PASSED
rollback;
