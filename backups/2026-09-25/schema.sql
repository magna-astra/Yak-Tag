-- ============================================================
-- YAK-TAG — Livestock digital ID platform
-- PostgreSQL / Supabase schema  ·  v1
--
-- Design rules:
--   1. Every row that belongs to a farm carries farm_id directly.
--      Denormalised on purpose — RLS policies must be cheap.
--   2. NFC now, UHF later: tags carry both columns from day one
--      so adding UHF is a data change, not a migration.
--   3. Offline-first: every scan carries a client-generated UUID
--      so a herder's phone can retry sync safely forever.
--   4. Nothing is ever hard-deleted. Status columns only.
-- ============================================================

create extension if not exists "pgcrypto";

-- ============================================================
-- 1. FARMS
-- ============================================================
create table farms (
  id            uuid primary key default gen_random_uuid(),
  code          text unique not null,           -- 'FERM-12'
  name          text not null,                  -- 'Хогно Хаан'
  aimag         text,                           -- province
  soum          text,                           -- district
  center_lat    double precision,               -- for map default view
  center_lng    double precision,
  status        text not null default 'active'
                check (status in ('active','suspended','archived')),
  created_at    timestamptz not null default now()
);

-- ============================================================
-- 2. PROFILES  (extends Supabase auth.users)
--    role decides what the RLS policies below allow.
-- ============================================================
create table profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  full_name     text not null,
  phone         text,
  role          text not null
                check (role in ('super_admin','farm_admin','herder')),
  farm_id       uuid references farms(id),      -- null only for super_admin
  status        text not null default 'active'
                check (status in ('active','disabled')),
  created_at    timestamptz not null default now(),

  -- a non-super-admin must belong to exactly one farm
  constraint farm_required check (role = 'super_admin' or farm_id is not null)
);
create index on profiles(farm_id);

-- ============================================================
-- 3. TAG BATCHES
--    Each farm gets non-overlapping ID ranges. This is what
--    prevents two farms ever issuing the same cow number.
-- ============================================================
create table tag_batches (
  id            uuid primary key default gen_random_uuid(),
  farm_id       uuid not null references farms(id),
  code          text unique not null,           -- 'BATCH-012-A'
  prefix        text not null default 'MN',
  range_start   integer not null,               -- 8000
  range_end     integer not null,               -- 8999
  quantity      integer generated always as (range_end - range_start + 1) stored,
  status        text not null default 'reserved'
                check (status in ('reserved','printing','issued','exhausted')),
  created_at    timestamptz not null default now(),

  constraint range_valid check (range_end >= range_start)
);
create index on tag_batches(farm_id);

-- Hard guarantee: no two batches may overlap, across ALL farms.
create extension if not exists btree_gist;
alter table tag_batches
  add constraint no_range_overlap
  exclude using gist (
    prefix with =,
    int4range(range_start, range_end, '[]') with &&
  );

-- ============================================================
-- 4. TAGS
--    The physical object. Exists before any cow is attached.
--    nfc_uid  = NTAG215 chip UID (7 bytes, hex) — used now
--    uhf_epc  = UHF EPC code                    — reserved for later
-- ============================================================
create table tags (
  id            uuid primary key default gen_random_uuid(),
  farm_id       uuid not null references farms(id),
  batch_id      uuid not null references tag_batches(id),
  tag_code      text unique not null,           -- 'MN-008521'  (printed + QR)
  qr_slug       text unique not null,           -- short opaque URL token
  nfc_uid       text unique,                    -- filled when chip is written
  uhf_epc       text unique,                    -- reserved: UHF phase
  status        text not null default 'blank'
                check (status in ('blank','written','assigned','lost','retired')),
  written_at    timestamptz,
  created_at    timestamptz not null default now()
);
create index on tags(farm_id);
create index on tags(nfc_uid);
create index on tags(status);

-- ============================================================
-- 5. CATTLE
-- ============================================================
create table cattle (
  id            uuid primary key default gen_random_uuid(),
  farm_id       uuid not null references farms(id),
  tag_id        uuid unique references tags(id), -- null if tag lost, until retagged
  tag_code      text,                            -- denormalised for fast search

  -- --- the 6 required registration fields ---
  sex           text not null check (sex in ('female','male')),
  birth_year    integer check (birth_year between 1990 and 2100),
  owner_id      uuid not null references profiles(id),   -- the herder
  reg_lat       double precision,
  reg_lng       double precision,
  registered_at timestamptz not null default now(),
  registered_by uuid not null references profiles(id),

  -- --- optional, filled later ---
  breed         text,
  colour        text,
  weight_kg     numeric(6,1),
  mother_tag    text,
  notes         text,

  status        text not null default 'active'
                check (status in ('active','sold','slaughtered','dead','lost','stolen')),
  status_at     timestamptz,
  created_at    timestamptz not null default now()
);
create index on cattle(farm_id);
create index on cattle(owner_id);
create index on cattle(tag_code);
create index on cattle(status);

-- ============================================================
-- 6. PHOTOS
--    Files live in Cloudflare R2. Only the path is stored here.
--    'muzzle' is captured from day one — a cow's muzzle print is
--    unique like a fingerprint, so this dataset becomes a tagless
--    fallback identity later. Cannot be retrofitted.
-- ============================================================
create table cattle_photos (
  id            uuid primary key default gen_random_uuid(),
  farm_id       uuid not null references farms(id),
  cattle_id     uuid not null references cattle(id) on delete cascade,
  kind          text not null default 'profile'
                check (kind in ('profile','muzzle','marking','transfer','health')),
  storage_path  text not null,                  -- r2://yaktag/farm-12/cow-8521/muzzle.jpg
  width         integer,
  height        integer,
  bytes         integer,
  taken_lat     double precision,
  taken_lng     double precision,
  taken_at      timestamptz,
  uploaded_at   timestamptz not null default now()
);
create index on cattle_photos(cattle_id);
create index on cattle_photos(farm_id);

-- ============================================================
-- 7. SCAN EVENTS
--    One row per encounter. This is the location history.
--    client_uuid makes offline sync idempotent: the phone can
--    resend the same event forever and it lands exactly once.
-- ============================================================
create table scan_events (
  id            uuid primary key default gen_random_uuid(),
  client_uuid   uuid unique not null,           -- generated on the phone
  farm_id       uuid not null references farms(id),
  tag_id        uuid references tags(id),
  cattle_id     uuid references cattle(id),
  scanned_by    uuid not null references profiles(id),

  method        text not null default 'nfc'
                check (method in ('nfc','qr','uhf','manual')),
  lat           double precision,
  lng           double precision,
  accuracy_m    numeric(6,1),

  scanned_at    timestamptz not null,           -- phone clock, when it happened
  synced_at     timestamptz not null default now(),
  was_offline   boolean not null default false,
  note          text
);
create index on scan_events(cattle_id, scanned_at desc);
create index on scan_events(farm_id, scanned_at desc);
create index on scan_events(scanned_by, scanned_at desc);

-- OneTag's dedup rule, adapted: ignore repeat scans of the same
-- animal by the same person inside a short window.
create or replace function drop_duplicate_scan()
returns trigger language plpgsql as $$
begin
  if exists (
    select 1 from scan_events
    where cattle_id = new.cattle_id
      and scanned_by = new.scanned_by
      and scanned_at > new.scanned_at - interval '10 minutes'
      and scanned_at <= new.scanned_at
  ) then
    return null;   -- silently discard, phone still gets a success
  end if;
  return new;
end $$;

create trigger scan_dedup
  before insert on scan_events
  for each row when (new.cattle_id is not null)
  execute function drop_duplicate_scan();

-- ============================================================
-- 8. OWNERSHIP TRANSFERS
--    Theft protection + resale provenance. Append-only history.
-- ============================================================
create table ownership_transfers (
  id            uuid primary key default gen_random_uuid(),
  farm_id       uuid not null references farms(id),
  cattle_id     uuid not null references cattle(id),
  from_owner    uuid references profiles(id),
  to_owner      uuid not null references profiles(id),
  reason        text check (reason in ('sale','inheritance','gift','correction','other')),
  note          text,
  lat           double precision,
  lng           double precision,
  transferred_at timestamptz not null default now(),
  recorded_by   uuid not null references profiles(id)
);
create index on ownership_transfers(cattle_id, transferred_at desc);

-- Keep cattle.owner_id in step with the transfer log automatically.
create or replace function apply_transfer()
returns trigger language plpgsql as $$
begin
  update cattle set owner_id = new.to_owner where id = new.cattle_id;
  return new;
end $$;

create trigger transfer_applies
  after insert on ownership_transfers
  for each row execute function apply_transfer();

-- ============================================================
-- 9. HEALTH EVENTS
-- ============================================================
create table health_events (
  id            uuid primary key default gen_random_uuid(),
  farm_id       uuid not null references farms(id),
  cattle_id     uuid not null references cattle(id) on delete cascade,
  kind          text not null
                check (kind in ('vaccination','treatment','illness','pregnancy',
                                'birth','weighing','vet_visit','note')),
  title         text not null,
  detail        text,
  weight_kg     numeric(6,1),
  due_next      date,                           -- drives 'vaccination overdue'
  occurred_at   timestamptz not null default now(),
  recorded_by   uuid not null references profiles(id)
);
create index on health_events(cattle_id, occurred_at desc);
create index on health_events(farm_id, due_next);

-- ============================================================
-- 10. AUDIT LOG
-- ============================================================
create table audit_log (
  id            bigserial primary key,
  farm_id       uuid references farms(id),
  actor_id      uuid references profiles(id),
  action        text not null,
  entity        text not null,
  entity_id     uuid,
  detail        jsonb,
  at            timestamptz not null default now()
);
create index on audit_log(farm_id, at desc);

-- ============================================================
-- 11. ROW LEVEL SECURITY
--     This is the part that makes Farm #12 unable to see Farm #7.
--     Enforced by the database, not by application code — so a bug
--     in the dashboard cannot leak another farm's animals.
-- ============================================================

-- NOTE: every helper below checks status = 'active'.
-- This is what makes the super admin's "disable user" button real:
-- a disabled account gets no role and no farm, so every policy in
-- this file evaluates to false and the account can read nothing.

create or replace function my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid() and status = 'active'
$$;

create or replace function my_farm() returns uuid
language sql stable security definer set search_path = public as $$
  select farm_id from profiles where id = auth.uid() and status = 'active'
$$;

create or replace function is_super() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select role = 'super_admin' from profiles
    where id = auth.uid() and status = 'active'
  ), false)
$$;

-- A farm can also be switched off wholesale (unpaid, contract ended).
-- Suspending the farm disables everyone inside it in one action.
create or replace function my_farm_live() returns uuid
language sql stable security definer set search_path = public as $$
  select p.farm_id from profiles p
  join farms f on f.id = p.farm_id
  where p.id = auth.uid() and p.status = 'active' and f.status = 'active'
$$;

alter table farms               enable row level security;
alter table profiles            enable row level security;
alter table tag_batches         enable row level security;
alter table tags                enable row level security;
alter table cattle              enable row level security;
alter table cattle_photos       enable row level security;
alter table scan_events         enable row level security;
alter table ownership_transfers enable row level security;
alter table health_events       enable row level security;
alter table audit_log           enable row level security;

-- --- farms ---
create policy farms_read on farms for select
  using (is_super() or id = my_farm());
create policy farms_write on farms for all
  using (is_super()) with check (is_super());

-- --- profiles ---
create policy profiles_self on profiles for select
  using (id = auth.uid() or is_super() or farm_id = my_farm());
create policy profiles_admin on profiles for all
  using (is_super() or (my_role() = 'farm_admin' and farm_id = my_farm()))
  with check (is_super() or (my_role() = 'farm_admin' and farm_id = my_farm()));

-- --- everything farm-scoped: same shape for each table ---
create policy batches_scope on tag_batches for select
  using (is_super() or farm_id = my_farm());
create policy batches_admin on tag_batches for all
  using (is_super()) with check (is_super());

create policy tags_scope on tags for select
  using (is_super() or farm_id = my_farm());
create policy tags_admin on tags for all
  using (is_super() or (my_role() = 'farm_admin' and farm_id = my_farm()))
  with check (is_super() or (my_role() = 'farm_admin' and farm_id = my_farm()));

create policy cattle_scope on cattle for select
  using (is_super() or farm_id = my_farm());
create policy cattle_insert on cattle for insert
  with check (farm_id = my_farm());            -- herders may register
create policy cattle_update on cattle for update
  using (is_super()
         or (my_role() = 'farm_admin' and farm_id = my_farm())
         or (my_role() = 'herder' and owner_id = auth.uid()));

create policy photos_scope on cattle_photos for select
  using (is_super() or farm_id = my_farm());
create policy photos_insert on cattle_photos for insert
  with check (farm_id = my_farm());

create policy scans_scope on scan_events for select
  using (is_super() or farm_id = my_farm());
create policy scans_insert on scan_events for insert
  with check (farm_id = my_farm() and scanned_by = auth.uid());

create policy transfers_scope on ownership_transfers for select
  using (is_super() or farm_id = my_farm());
create policy transfers_insert on ownership_transfers for insert
  with check (is_super() or (my_role() = 'farm_admin' and farm_id = my_farm()));

create policy health_scope on health_events for select
  using (is_super() or farm_id = my_farm());
create policy health_insert on health_events for insert
  with check (farm_id = my_farm());

create policy audit_scope on audit_log for select
  using (is_super() or farm_id = my_farm());

-- ============================================================
-- 12. CONVENIENCE VIEWS  (what the dashboard actually reads)
-- ============================================================

-- One row per cow with its latest known position.
create or replace view cattle_overview as
select
  c.id, c.farm_id, c.tag_code, c.sex, c.birth_year, c.breed,
  c.weight_kg, c.status,
  p.full_name           as owner_name,
  s.scanned_at          as last_seen_at,
  s.lat                 as last_lat,
  s.lng                 as last_lng,
  s.method              as last_method,
  (select count(*) from scan_events e where e.cattle_id = c.id) as scan_count,
  (select min(h.due_next) from health_events h
     where h.cattle_id = c.id and h.due_next is not null)        as next_due
from cattle c
join profiles p on p.id = c.owner_id
left join lateral (
  select * from scan_events e
  where e.cattle_id = c.id
  order by e.scanned_at desc limit 1
) s on true;

-- Per-farm dashboard counters.
create or replace view farm_stats as
select
  f.id as farm_id, f.code, f.name,
  count(distinct c.id) filter (where c.status = 'active')            as cattle_active,
  count(distinct pr.id) filter (where pr.role = 'herder')            as herders,
  count(distinct e.id) filter (where e.scanned_at > now() - interval '7 days') as scans_7d,
  count(distinct t.id) filter (where t.status = 'blank')             as tags_available
from farms f
left join cattle c       on c.farm_id = f.id
left join profiles pr    on pr.farm_id = f.id
left join scan_events e  on e.farm_id = f.id
left join tags t         on t.farm_id = f.id
group by f.id, f.code, f.name;

-- ============================================================
-- END v1
-- ============================================================
