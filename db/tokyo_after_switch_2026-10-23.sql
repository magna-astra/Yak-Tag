-- ============================================================
-- YAK-TAG — one-off, Tokyo project (mjijgxfmkgtxmpbmshtl), 2026-10-23
-- Run ONCE in the Tokyo SQL editor. Safe to run twice.
--
-- 1. "Today" = today in Mongolia. v21 set this on the Sydney database
--    ("alter database"); it is a database setting, not part of the
--    tables, so the copy didn't bring it. Without it current_date is
--    still yesterday until 08:00 in Ulaanbaatar (milk today, milk
--    edit window). Takes effect on new connections (within ~30 min).
--
-- 2. Two animals changed in Sydney between the copy and the switch
--    (found by move_database.py catchup):
--      61ec76d8… reported LOST at 22:10 (UB) → lost in Tokyo too
--      7c62c25a… marked FOUND                → active in Tokyo too
--    Each update only applies if Tokyo still has the copy-time value,
--    so nothing done in Tokyo since the switch is overwritten.
--    Triggers are off for these two rows: the alerts and history lines
--    were already sent / copied from Sydney.
-- ============================================================

alter database postgres set timezone to 'Asia/Ulaanbaatar';

begin;
set local session_replication_role = replica;

update public.cattle
   set status = 'lost', reported_lost_at = '2026-10-23 14:10:47.766017+00'
 where id = '61ec76d8-cd56-48b8-a477-7293b3e2df5b' and status = 'active' and reported_lost_at is null;

update public.cattle
   set status = 'active', reported_lost_at = null
 where id = '7c62c25a-02a7-409c-91c4-a244f9172f4a' and status = 'lost'
   and reported_lost_at = '2026-10-20 03:41:41.721364+00';

commit;

-- check: lost / active, and the database's own time zone
select id, tag_code, status, reported_lost_at,
       (select setconfig from pg_db_role_setting
         where setdatabase = (select oid from pg_database where datname = current_database()) and setrole = 0) as db_settings
  from public.cattle
 where id in ('61ec76d8-cd56-48b8-a477-7293b3e2df5b', '7c62c25a-02a7-409c-91c4-a244f9172f4a');
