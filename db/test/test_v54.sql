-- Tests for schema_v54 (a herder corrects a day's milk once) on the local
-- replay DB. One transaction, rolled back.
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
-- what the app sends: PostgREST upsert on (cattle_id, yield_date)
create function t.milk(farm uuid, cow uuid, who uuid, l numeric, d date) returns void language sql as $$
  insert into public.milk_yield (farm_id, cattle_id, recorded_by, liters, yield_date)
  values (farm, cow, who, l, d)
  on conflict (cattle_id, yield_date) do update
    set farm_id = excluded.farm_id, recorded_by = excluded.recorded_by, liters = excluded.liters
$$;
grant execute on all functions in schema t to public;

select id as herder, farm_id as farm from profiles where role = 'herder' and farm_id is not null order by id limit 1 \gset
select id as herder2 from profiles where role = 'herder' and farm_id = :'farm' and id <> :'herder' order by id limit 1 \gset
select id as fadmin from profiles where role = 'farm_admin' and farm_id = :'farm' order by id limit 1 \gset
select id as cow, (select id from cattle where farm_id = :'farm' and status = 'active' order by id offset 1 limit 1) as cow2
  from cattle where farm_id = :'farm' and status = 'active' order by id limit 1 \gset
update tags set paused_at = null where id in (select tag_id from cattle where id in (:'cow', :'cow2'));
update cattle set owner_id = :'herder' where id in (:'cow', :'cow2');      -- a herder enters milk for his own animals
delete from milk_yield where cattle_id in (:'cow', :'cow2') and yield_date >= current_date - 1;

-- ---------- first save, a resend, the one correction ----------
set role authenticated; select t.as_(:'herder');
select t.milk(:'farm', :'cow', :'herder', 10, current_date);
select t.milk(:'farm', :'cow', :'herder', 10, current_date);          -- same number again (double tap / resend)
reset role;
select t.ok((select edit_count = 0 and not locked from milk_yield where cattle_id = :'cow' and yield_date = current_date),
            'first save + a resend of the same number: no correction used');

set role authenticated; select t.as_(:'herder');
select t.milk(:'farm', :'cow', :'herder', 12, current_date);
reset role;
select t.ok((select liters = 12 and edit_count = 1 and locked from milk_yield where cattle_id = :'cow' and yield_date = current_date),
            'the one correction is saved, and the day is locked');

-- ---------- no second correction, by any road ----------
set role authenticated; select t.as_(:'herder');
select t.err(format('select t.milk(%L, %L, %L, 13, current_date)', :'farm', :'cow', :'herder'),
             'row-level security', 'second correction by the herder refused');
update milk_yield set liters = 14 where cattle_id = :'cow' and yield_date = current_date;
update milk_yield set locked = false, edit_count = 0 where cattle_id = :'cow' and yield_date = current_date;
reset role;
select t.ok((select liters = 12 and locked from milk_yield where cattle_id = :'cow' and yield_date = current_date),
            'a plain update / unlocking from the browser changes nothing');

-- ---------- admins can still correct ----------
set role authenticated; select t.as_(:'fadmin');
select t.milk(:'farm', :'cow', :'fadmin', 11.5, current_date);
reset role;
select t.ok((select liters = 11.5 and locked from milk_yield where cattle_id = :'cow' and yield_date = current_date),
            'the farm admin corrects a locked day');

-- ---------- yesterday: same rule; another herder: not his entry ----------
set role authenticated; select t.as_(:'herder');
select t.milk(:'farm', :'cow2', :'herder', 8, current_date - 1);
select t.milk(:'farm', :'cow2', :'herder', 9, current_date - 1);
select t.err(format('select t.milk(%L, %L, %L, 9.5, current_date - 1)', :'farm', :'cow2', :'herder'),
             'row-level security', 'yesterday: one correction too, then refused');
select t.as_(:'herder2');
select t.err(format('select t.milk(%L, %L, %L, 7, current_date)', :'farm', :'cow', :'herder2'),
             'row-level security', 'another herder cannot change the entry');
reset role;

-- ---------- v54 locks entries corrected before it ----------
alter table milk_yield disable trigger milk_edit_counter;
update milk_yield set edit_count = 2, locked = false where cattle_id = :'cow2' and yield_date = current_date - 1;
alter table milk_yield enable trigger milk_edit_counter;
\i db/schema_v54_milk_one_edit.sql
select t.ok((select locked from milk_yield where cattle_id = :'cow2' and yield_date = current_date - 1),
            'v54 run again: an entry corrected twice under the old rule is locked');
select t.ok((select count(*) = 0 from milk_yield where edit_count >= 1 and not locked),
            'no corrected entry left unlocked');

rollback;
