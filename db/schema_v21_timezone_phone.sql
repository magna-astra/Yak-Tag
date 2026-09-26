-- ============================================================
-- YAK-TAG — schema patch v21
-- Mongolia calendar date + contact phone validation.
--
-- Safe to run on the live project: no table rewrites, no data
-- changes, and existing rows are left exactly as they are.
-- Safe to run twice.
-- ============================================================

-- ============================================================
-- 1. "TODAY" MEANS TODAY IN MONGOLIA
--
-- The database ran in UTC, so current_date was still yesterday
-- until 08:00 in Ulaanbaatar. Affected: cattle_dashboard.milk_today,
-- milk_this_month at month boundaries, and the herder milk edit
-- window (policy milk_update: "yesterday and today").
--
-- Stored timestamps (timestamptz) do NOT change — they are absolute
-- moments. Only how "today" is computed and how times are displayed
-- in the SQL editor change.
--
-- Takes effect on new connections. If the dashboard still shows
-- the old date a few minutes later: Project Settings → General →
-- Restart project (or just wait for the connection pool to cycle).
-- ============================================================
alter database postgres set timezone to 'Asia/Ulaanbaatar';

-- ============================================================
-- 2. CONTACT PHONE MUST LOOK LIKE A PHONE NUMBER
--
-- set_contact_phone accepted any text. The phone is shown on the
-- owner's page and dialled from the public tap page, so arbitrary
-- text there is both a data problem and an injection risk.
--
-- Deliberately a trigger, not a CHECK constraint: a CHECK is
-- re-tested on every UPDATE of the row, so one old badly-formatted
-- number would start blocking unrelated saves (photo, status,
-- owner). This only checks when the phone itself is being changed.
-- ============================================================
create or replace function check_contact_phone()
returns trigger language plpgsql as $$
begin
  if new.contact_phone is not null
     and new.contact_phone is distinct from
         (case when tg_op = 'UPDATE' then old.contact_phone end)
     and new.contact_phone !~ '^\+?[0-9][0-9 ()-]{5,19}$' then
    raise exception 'Invalid phone number. Use digits only, e.g. 99112233.';
  end if;
  return new;
end $$;

drop trigger if exists cattle_contact_phone_check on cattle;
create trigger cattle_contact_phone_check
  before insert or update of contact_phone on cattle
  for each row execute function check_contact_phone();

-- ============================================================
-- CHECK AFTER RUNNING
-- ============================================================
-- Should show Asia/Ulaanbaatar (open a NEW SQL editor tab first):
--   show timezone;
--   select current_date, now();
--
-- Existing numbers that would not pass the new rule. They keep
-- working; fix them by hand when convenient:
--   select tag_code, contact_phone from cattle
--   where contact_phone is not null
--     and contact_phone !~ '^\+?[0-9][0-9 ()-]{5,19}$';
