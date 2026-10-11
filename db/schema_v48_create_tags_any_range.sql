-- ============================================================
-- YAK-TAG — schema patch v48
-- "+ Таг үүсгэх" accepts ANY range and says what already exists.
--
-- Before: a range that crossed the edge of an existing batch was
-- refused ("хэсэгчлэн давхцаж байна") and nothing was created; numbers
-- that already existed were only counted.
-- Now: numbers that already exist are skipped and reported (how many,
-- first … last); every missing number is created. Numbers inside an
-- existing batch join that batch; each gap between batches gets its own
-- new batch (batch ranges still never overlap — no_range_overlap).
-- Super admin only, as before. Same name and arguments.
--
-- Safe on the live project and safe to run twice.
-- ============================================================

do $$
begin
  if to_regprocedure('public.is_super()') is null or to_regclass('public.tag_batches') is null then
    raise exception 'Wrong database: open the YAK-TAG project oxfbxqclqfglpzgzizhq and run again.';
  end if;
end $$;

create or replace function public.admin_create_tags(
  p_prefix  text,
  p_from    integer,
  p_to      integer,
  p_farm_id uuid
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_prefix   text := upper(trim(coalesce(p_prefix, '')));
  v_existing int;
  v_ex_first text;
  v_ex_last  text;
  v_created  int := 0;
  v_batches  int := 0;
  v_new_first text;
  v_new_last  text;
  seg        record;
begin
  if not coalesce(is_super(), false) then raise exception 'Зөвхөн ерөнхий админ.'; end if;
  if v_prefix !~ '^[A-Z]{1,6}$' then raise exception 'Угтвар зөвхөн латин үсэг (жишээ: YT).'; end if;
  if p_from is null or p_to is null or p_from < 0 or p_to < p_from then
    raise exception 'Дугаарын хүрээ буруу.';
  end if;
  if p_to > 999999 then raise exception 'Дугаар 999999-аас их байж болохгүй.'; end if;
  if p_to - p_from + 1 > 2000 then raise exception 'Нэг удаад 2000-аас ихгүй таг.'; end if;
  if not exists (select 1 from farms where id = p_farm_id) then
    raise exception 'Ферм олдсонгүй.';
  end if;

  -- what already exists (in any farm)
  select count(*), min(t.tag_code), max(t.tag_code)
    into v_existing, v_ex_first, v_ex_last
    from tags t
   where t.tag_code in (select v_prefix || '-' || lpad(n::text, 6, '0') from generate_series(p_from, p_to) n);

  -- a new batch for every gap (numbers not inside any existing batch)
  for seg in
    select min(n) as s, max(n) as e
      from (select n, n - row_number() over (order by n) as grp
              from generate_series(p_from, p_to) n
             where not exists (select 1 from tag_batches b
                                where b.prefix = v_prefix
                                  and n between b.range_start and b.range_end)) x
     group by grp
     order by 1
  loop
    insert into tag_batches (farm_id, code, prefix, range_start, range_end, status)
    values (p_farm_id, v_prefix || '-' || seg.s || '-' || seg.e, v_prefix, seg.s, seg.e, 'issued');
    v_batches := v_batches + 1;
  end loop;

  -- every missing number, in the batch that covers it
  with ins as (
    insert into tags (farm_id, batch_id, tag_code, qr_slug, status)
    select p_farm_id,
           (select b.id from tag_batches b
             where b.prefix = v_prefix and n between b.range_start and b.range_end
             order by b.range_start limit 1),
           v_prefix || '-' || lpad(n::text, 6, '0'),
           substr(replace(gen_random_uuid()::text, '-', ''), 1, 12),
           'blank'
      from generate_series(p_from, p_to) n
    on conflict (tag_code) do nothing
    returning tag_code
  )
  select count(*), min(tag_code), max(tag_code) into v_created, v_new_first, v_new_last from ins;

  insert into audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  values (p_farm_id, auth.uid(), 'tags_create', 'tags', null,
          jsonb_build_object('prefix', v_prefix, 'from', p_from, 'to', p_to,
                             'created', v_created, 'already_existed', v_existing,
                             'new_batches', v_batches));

  return jsonb_build_object(
    'created', v_created, 'created_first', v_new_first, 'created_last', v_new_last,
    'skipped', v_existing, 'existing_first', v_ex_first, 'existing_last', v_ex_last,
    'new_batches', v_batches);
end $$;

revoke all on function public.admin_create_tags(text, integer, integer, uuid) from public, anon;
grant execute on function public.admin_create_tags(text, integer, integer, uuid) to authenticated;

notify pgrst, 'reload schema';
