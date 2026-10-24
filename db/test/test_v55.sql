-- Tests for schema_v55 (horses, stage 1) on the local replay DB.
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
select id as herder2 from profiles where role = 'herder' and farm_id = :'farm' and id <> :'herder' order by id limit 1 \gset
select id as fadmin from profiles where role = 'farm_admin' and farm_id = :'farm' order by id limit 1 \gset
select tag_code as blank from tags t where status = 'blank' and farm_id = :'farm'
   and not exists (select 1 from cattle c where c.tag_id = t.id) order by tag_code limit 1 \gset
select count(*) as n0 from cattle \gset

-- ---------- breeds ----------
select t.ok((select array_agg(name_mn order by sort_order) from breeds where species = 'horse' and active and not is_other)
            = array['Монгол адуу','Галшар','Тэс','Дархад','Мянгад','Өндөршил','Эрлийз','Англи цэвэр цусны','Араб','Ахалтекин','Будённый','Кабардин','Орлов'],
            'official horse breeds offered (Жаргалант hidden)');
select t.ok((select official_code from breeds where code = 'tes') = '0103', 'official code kept (Тэс 0103)');

-- ---------- a horse with no YAK-TAG tag ----------
set role authenticated; select t.as_(:'herder');
select register_horse('female', extract(year from now())::int - 4, 'galshar', null, 'хээр', false,
                      array['халзан', 'сартай', 'халзан', ' '], '956 000 012 345 678', 'mgl-0123456789',
                      47.9, 106.9) as h1 \gset
reset role;
select t.ok((select species = 'horse' and tag_code is null and tag_id is null and breed = 'Галшар'
                    and chip_no = '956000012345678' and national_id = 'MGL0123456789'
                    and markings = array['сартай','халзан'] and colour = 'хээр' and not castrated
                    and owner_id = :'herder' and farm_id = :'farm'
               from cattle where id = :'h1'),
            'no tag: horse saved with chip, MGL number, зүс, markings (spaces/dashes and doubles cleaned)');
set role authenticated; select t.as_(:'herder');
select t.ok((select species = 'horse' and chip_no = '956000012345678' and markings = array['сартай','халзан']
               from cattle_dashboard where id = :'h1'), 'the herder''s list shows it with species and horse fields');

-- ---------- what is refused (and leaves nothing behind) ----------
select t.err(format($q$select register_horse('male', 2020, 'galshar', null, null, false, '{}', '956000012345678')$q$),
             'чипийн дугаартай адуу аль хэдийн', 'same chip twice refused');
select t.err(format($q$select register_horse('male', 2020, 'galshar', null, null, false, '{}', null, 'MGL0123456789')$q$),
             'улсын дугаартай адуу аль хэдийн', 'same national number twice refused');
select t.err($q$select register_horse('male', 2020, 'galshar', null, null, false, '{}', '12345')$q$,
             '15 оронтой', 'short chip number refused');
select t.err($q$select register_horse('male', 2020, 'galshar', null, null, false, '{}', null, 'MN12345')$q$,
             'MGL \+ 10', 'wrong national number refused');
select t.err($q$select register_horse('female', 2020, 'galshar', null, null, true)$q$,
             'Агт гэдэг нь эр', 'a castrated mare refused');
select t.err($q$select register_horse('female', 2020, 'jargalant')$q$, 'Адууны үүлдрээ', 'hidden breed (Жаргалант) refused for new horses');
select t.err($q$select register_horse('female', 2020, 'yak')$q$, 'Адууны үүлдрээ', 'a cattle breed refused');
select t.err($q$select register_horse('female', 2020, 'horse_other')$q$, 'Бусад', '"Бусад" needs the name');
reset role;
select t.ok((select count(*) from cattle) = :n0 + 1, 'refused registrations left nothing behind');

-- ---------- with a YAK-TAG tag ----------
set role authenticated; select t.as_(:'herder');
select register_horse('male', 2019, 'mongol_horse', null, 'хул', true, '{}', null, null, null, null, null, :'blank') as h2 \gset
reset role;
select t.ok((select c.tag_code = :'blank' and c.species = 'horse' and c.castrated and c.colour = 'хул' and tg.status = 'assigned'
               from cattle c join tags tg on tg.id = c.tag_id where c.id = :'h2'),
            'with a tag: the tag is used (assigned), агт saved');
set role authenticated; select t.as_(:'herder');
select t.err(format($q$select register_horse('male', 2019, 'mongol_horse', null, null, false, '{}', null, null, null, null, null, %L)$q$, :'blank'),
             'аль хэдийн бүртгэгдсэн', 'the same tag again refused (tag rules from register_cattle)');

-- ---------- editing ----------
select set_horse_details(:'h1', '956000012345679', null, false, array['булаг'], 'зээрд');
reset role;
select t.ok((select chip_no = '956000012345679' and national_id is null and markings = array['булаг'] and colour = 'зээрд'
               from cattle where id = :'h1'), 'owner edits the horse details');
select t.ok((select count(*) from audit_log where entity_id = :'h1' and action = 'set_horse_details') = 2,
            'each change in the history (registration + edit)');
set role authenticated; select t.as_(:'herder2');
select t.err(format('select set_horse_details(%L, null, null, false, null, null)', :'h1'), 'эрхгүй', 'another herder cannot edit');
select t.as_(:'fadmin');
select set_horse_details(:'h1', '956000012345679', 'MGL0000000001', false, '{}', 'зээрд');
reset role;
select t.ok((select national_id = 'MGL0000000001' from cattle where id = :'h1'), 'the farm admin edits');
select id as cow from cattle where species is distinct from 'horse' and farm_id = :'farm' limit 1 \gset
set role authenticated; select t.as_(:'fadmin');
select t.err(format('select set_horse_details(%L, null, null, false, null, null)', :'cow'), 'зөвхөн адуунд', 'not for cattle');
reset role;

-- ---------- brand photo, permissions ----------
select t.ok(exists (select 1 from pg_constraint where conrelid = 'cattle_photos'::regclass
                      and pg_get_constraintdef(oid) like '%brand%'), 'brand (тамга) is a photo kind');
select t.ok((select count(*) from pg_constraint where conrelid = 'cattle_photos'::regclass and contype = 'c'
               and pg_get_constraintdef(oid) ilike '%kind%') = 1, 'one kind check only (the old one replaced)');
select t.ok(not has_function_privilege('anon', 'public.register_horse(text,integer,text,text,text,boolean,text[],text,text,double precision,double precision,text,text)', 'execute')
            and not has_function_privilege('anon', 'public.set_horse_details(uuid,text,text,boolean,text[],text)', 'execute'),
            'visitors cannot call the horse functions');
select t.ok(has_function_privilege('authenticated', 'public.register_horse(text,integer,text,text,text,boolean,text[],text,text,double precision,double precision,text,text)', 'execute'),
            'logged-in users can');

rollback;
