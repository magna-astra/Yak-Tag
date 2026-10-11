-- Objects the live database has but NO file in db/ creates (made by hand
-- early on). Reconstructed from how the patches use them, so the replay
-- can continue. milk_yield's real definition must still be recovered from
-- the live project.
\set ON_ERROR_STOP 1
create table if not exists milk_yield (
  id          uuid primary key default gen_random_uuid(),
  farm_id     uuid not null references farms(id),
  cattle_id   uuid not null references cattle(id) on delete cascade,
  recorded_by uuid references profiles(id),
  liters      numeric(6,2) not null check (liters >= 0),
  yield_date  date not null default current_date,
  created_at  timestamptz not null default now(),
  unique (cattle_id, yield_date)
);
alter table milk_yield enable row level security;
create policy milk_insert on milk_yield for insert
  with check (is_super() or farm_id = my_farm());
grant all on milk_yield to authenticated;

do $$ begin
  if to_regclass('public.cattle_overview') is null then execute 'create view cattle_overview as select c.id from cattle c'; end if;
  if to_regclass('public.farm_stats') is null then execute 'create view farm_stats as select f.id from farms f'; end if;
  if to_regclass('public.cattle_dashboard') is null then execute 'create view cattle_dashboard as select c.id from cattle c'; end if;
end $$;

-- the real herder login the demo patches (v6, v8, v12) hard-code
insert into auth.users (id, email) values ('d422690e-534a-49b7-b510-c347b4170224', '99000004@yaktag.invalid')
  on conflict do nothing;
insert into profiles (id, full_name, phone, role, farm_id)
  select 'd422690e-534a-49b7-b510-c347b4170224', 'Бат-Эрдэнэ', '99000004', 'herder', id from farms where code = 'FERM-12'
  on conflict do nothing;
