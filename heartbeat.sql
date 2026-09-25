-- ============================================================
-- YAK-TAG — heartbeat table for the keep-alive workflow
-- Run this once in the Supabase SQL editor.
--
-- The keep-alive writes a row here every 2 days. A write is
-- unambiguous database activity, unlike a tiny read.
-- ============================================================

create table if not exists heartbeat (
  id        integer primary key default 1,
  last_ping timestamptz not null default now(),
  source    text,
  constraint only_one_row check (id = 1)
);

insert into heartbeat (id, last_ping, source)
values (1, now(), 'init')
on conflict (id) do nothing;

-- Locked down: only the service key may touch it.
-- No policies are created, so anon and authenticated get nothing.
alter table heartbeat enable row level security;

-- Check it worked:
--   select * from heartbeat;
