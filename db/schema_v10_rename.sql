-- ============================================================
-- YAK-TAG — schema patch v10
-- Simpler farm names.
-- ============================================================

update farms set name = 'Наран'  where code = 'FERM-12';
update farms set name = 'Хангай' where code = 'FERM-07';
update farms set name = 'Тэрэлж' where code = 'FERM-03';

-- check
--   select code, name, aimag, soum from farms order by code;
