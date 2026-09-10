-- ============================================================
-- YAK-TAG — seed / test data  ·  run AFTER schema.sql
--
-- BEFORE RUNNING:
-- 1. In Supabase → Authentication → Users, create 5 test users:
--      super@yaktag.test        (super admin)
--      admin12@yaktag.test      (Farm 12 admin)
--      admin07@yaktag.test      (Farm 7 admin)
--      bat@yaktag.test          (herder, Farm 12)
--      ganzo@yaktag.test        (herder, Farm 12)
-- 2. Copy each user's UUID and paste it below.
-- 3. Run this whole file in the SQL editor.
-- ============================================================

do $$
declare
  -- ⬇⬇⬇ PASTE THE 5 UUIDs FROM SUPABASE AUTH HERE ⬇⬇⬇
  u_super   uuid := '00000000-0000-0000-0000-000000000001';
  u_adm12   uuid := '00000000-0000-0000-0000-000000000002';
  u_adm07   uuid := '00000000-0000-0000-0000-000000000003';
  u_bat     uuid := '00000000-0000-0000-0000-000000000004';
  u_ganzo   uuid := '00000000-0000-0000-0000-000000000005';
  -- ⬆⬆⬆ ------------------------------------------- ⬆⬆⬆

  f12 uuid; f07 uuid; f03 uuid;
  b12 uuid; b07 uuid;
  t_id uuid; c_id uuid;
  n integer;
  owner uuid;
begin

-- ---------- farms ----------
insert into farms (code, name, aimag, soum, center_lat, center_lng)
values ('FERM-12','Хогно Хаан','Булган','Рашаант', 47.9212, 106.9187)
returning id into f12;

insert into farms (code, name, aimag, soum, center_lat, center_lng)
values ('FERM-07','Тэрэлж','Төв','Эрдэнэ', 47.8840, 107.4600)
returning id into f07;

insert into farms (code, name, aimag, soum, center_lat, center_lng)
values ('FERM-03','Хустай','Төв','Алтанбулаг', 47.7300, 105.9000)
returning id into f03;

-- ---------- people ----------
insert into profiles (id, full_name, phone, role, farm_id) values
  (u_super, 'Ерөнхий админ', '+976 9900 0000', 'super_admin', null),
  (u_adm12, 'Дэлгэрмаа',     '+976 9911 1111', 'farm_admin',  f12),
  (u_adm07, 'Түвшин',        '+976 9922 2222', 'farm_admin',  f07),
  (u_bat,   'Бат-Эрдэнэ',    '+976 9933 3333', 'herder',      f12),
  (u_ganzo, 'Ганзориг',      '+976 9944 4444', 'herder',      f12);

-- ---------- tag batches (non-overlapping ranges) ----------
insert into tag_batches (farm_id, code, prefix, range_start, range_end, status)
values (f12, 'BATCH-012-A', 'MN', 8000, 8999, 'issued') returning id into b12;

insert into tag_batches (farm_id, code, prefix, range_start, range_end, status)
values (f07, 'BATCH-007-A', 'MN', 7000, 7999, 'issued') returning id into b07;

insert into tag_batches (farm_id, code, prefix, range_start, range_end, status)
values (f03, 'BATCH-003-A', 'MN', 3000, 3999, 'reserved');

-- ---------- 50 tags + cattle for Farm 12 ----------
for n in 0..49 loop
  owner := case when n % 2 = 0 then u_bat else u_ganzo end;

  insert into tags (farm_id, batch_id, tag_code, qr_slug, nfc_uid, status, written_at)
  values (
    f12, b12,
    'MN-00' || (8000 + n),
    encode(gen_random_bytes(6), 'hex'),
    '04' || lpad(to_hex(1000000 + n), 12, '0'),
    'assigned', now() - (n || ' days')::interval
  ) returning id into t_id;

  insert into cattle (
    farm_id, tag_id, tag_code, sex, birth_year, owner_id,
    reg_lat, reg_lng, registered_by, breed, weight_kg
  ) values (
    f12, t_id, 'MN-00' || (8000 + n),
    case when n % 3 = 0 then 'male' else 'female' end,
    2019 + (n % 6),
    owner,
    47.9212 + (random() - 0.5) * 0.18,
    106.9187 + (random() - 0.5) * 0.28,
    owner,
    case when n % 4 = 0 then 'Эрлийз' else 'Монгол' end,
    340 + (random() * 160)::numeric(6,1)
  ) returning id into c_id;

  -- 1–6 scan events per cow, spread over the last 90 days
  insert into scan_events (client_uuid, farm_id, tag_id, cattle_id, scanned_by,
                           method, lat, lng, accuracy_m, scanned_at, was_offline)
  select
    gen_random_uuid(), f12, t_id, c_id, owner,
    case when random() < 0.7 then 'nfc' else 'qr' end,
    47.9212 + (random() - 0.5) * 0.2,
    106.9187 + (random() - 0.5) * 0.3,
    (4 + random() * 20)::numeric(6,1),
    now() - ((random() * 90)::int || ' days')::interval
          - ((random() * 600)::int || ' minutes')::interval,
    random() < 0.35
  from generate_series(1, 1 + (random() * 5)::int);

  -- vaccination on roughly every third animal
  if n % 3 = 0 then
    insert into health_events (farm_id, cattle_id, kind, title, due_next,
                               occurred_at, recorded_by)
    values (f12, c_id, 'vaccination', 'Шүлхий өвчний вакцин',
            (current_date + ((random() * 200)::int - 40)),
            now() - ((random() * 300)::int || ' days')::interval,
            u_adm12);
  end if;
end loop;

-- ---------- a few cattle for Farm 7 (to prove isolation) ----------
for n in 0..9 loop
  insert into tags (farm_id, batch_id, tag_code, qr_slug, nfc_uid, status)
  values (f07, b07, 'MN-00' || (7000 + n),
          encode(gen_random_bytes(6),'hex'),
          '04' || lpad(to_hex(2000000 + n), 12, '0'), 'assigned')
  returning id into t_id;

  insert into cattle (farm_id, tag_id, tag_code, sex, birth_year, owner_id,
                      reg_lat, reg_lng, registered_by, breed)
  values (f07, t_id, 'MN-00' || (7000 + n), 'female', 2021, u_adm07,
          47.8840, 107.4600, u_adm07, 'Монгол')
  returning id into c_id;
end loop;

-- ---------- spare blank tags ----------
insert into tags (farm_id, batch_id, tag_code, qr_slug, status)
select f12, b12, 'MN-00' || (8050 + g), encode(gen_random_bytes(6),'hex'), 'blank'
from generate_series(0, 24) g;

raise notice 'Seed complete: 3 farms, 5 users, 60 cattle, 25 blank tags.';
end $$;

-- ============================================================
-- VERIFY THE SCOPING WORKS
-- ============================================================
-- Log in to your app as admin12@yaktag.test and run:
--     select count(*) from cattle;
-- Expect 50 — NOT 60. If you see 60, RLS is not active.
--
-- As super@yaktag.test the same query must return 60.
--
-- Overlap protection check — this MUST fail:
--     insert into tag_batches (farm_id, code, prefix, range_start, range_end)
--     values ((select id from farms where code='FERM-03'),
--             'BAD-BATCH','MN', 8500, 8600);
-- Expected: conflicting key value violates exclusion constraint
-- ============================================================
