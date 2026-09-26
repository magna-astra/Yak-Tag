-- ============================================================
-- YAK-TAG — schema patch v29
-- Expected birth date was missing when the breed was chosen late.
--
-- v28 computed expected_date once, when the event was saved, from
-- the animal's breed. Existing animals had no breed yet, so a
-- breeding saved before choosing the breed got no date — and
-- choosing the breed afterwards did not fill it in.
--
-- Fix:
--   1. fill_expected_dates(cattle) computes every missing date for
--      one animal from its current breed;
--   2. set_cattle_breed calls it after changing the breed;
--   3. a one-time backfill runs it for all animals now.
-- Dates typed in by hand (or already computed) are never changed.
--
-- Safe on the live project and safe to run twice.
-- ============================================================

create or replace function fill_expected_dates(p_cattle_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_len integer;
  n1 integer; n2 integer; n3 integer;
begin
  select gestation_days(breed_code, species) into v_len from cattle where id = p_cattle_id;
  if v_len is null then return 0; end if;

  -- breeding: date + pregnancy length
  update repro_events set expected_date = event_date + v_len
  where cattle_id = p_cattle_id and kind = 'insemination' and expected_date is null;
  get diagnostics n1 = row_count;

  -- pregnant check with foetal age: check date - age + length
  update repro_events set expected_date = event_date - foetal_age_days + v_len
  where cattle_id = p_cattle_id and kind = 'pregnancy_check' and result = 'pregnant'
    and foetal_age_days is not null and expected_date is null;
  get diagnostics n2 = row_count;

  -- pregnant check without age: take the latest breeding's date before it
  update repro_events e set expected_date = (
      select i.expected_date from repro_events i
      where i.cattle_id = e.cattle_id and i.kind = 'insemination'
        and i.event_date <= e.event_date and i.expected_date is not null
      order by i.event_date desc, i.created_at desc limit 1)
  where e.cattle_id = p_cattle_id and e.kind = 'pregnancy_check' and e.result = 'pregnant'
    and e.foetal_age_days is null and e.expected_date is null;
  get diagnostics n3 = row_count;

  return n1 + n2 + n3;
end $$;

revoke all on function fill_expected_dates(uuid) from public, anon, authenticated;
-- (internal only: called by set_cattle_breed and the backfill below)

-- set_cattle_breed: same as v28, plus the recalculation at the end.
create or replace function set_cattle_breed(
  p_cattle_id  uuid,
  p_breed_code text,
  p_breed_text text default null
) returns void language plpgsql security definer set search_path = public as $$
declare
  c  record;
  b  record;
begin
  select id, farm_id, owner_id into c from cattle where id = p_cattle_id;
  if not found then raise exception 'Мал олдсонгүй.'; end if;
  if not (is_super()
          or (my_role() = 'farm_admin' and c.farm_id = my_farm())
          or (my_role() is not null and c.owner_id = auth.uid())) then
    raise exception 'Зөвхөн эзэмшигч эсвэл админ.';
  end if;

  select * into b from breeds where code = p_breed_code and active;
  if not found then raise exception 'Үүлдэр сонгоно уу.'; end if;
  if b.is_other and nullif(trim(p_breed_text), '') is null then
    raise exception '"Бусад" бол үүлдрийн нэрийг бичнэ үү.';
  end if;

  update cattle
     set species = b.species,
         breed_code = b.code,
         breed = case when b.is_other then trim(p_breed_text) else b.name_mn end
   where id = p_cattle_id;

  perform fill_expected_dates(p_cattle_id);
end $$;

-- One-time backfill for everything already saved.
select sum(fill_expected_dates(c.id)) as dates_filled
from cattle c
where c.breed_code is not null
  and exists (select 1 from repro_events e where e.cattle_id = c.id and e.expected_date is null);

notify pgrst, 'reload schema';

-- ============================================================
-- CHECK: breedings still without a date (their animal has no breed):
--   select c.tag_code, e.event_date from repro_events e
--   join cattle c on c.id = e.cattle_id
--   where e.kind = 'insemination' and e.expected_date is null;
-- ============================================================
