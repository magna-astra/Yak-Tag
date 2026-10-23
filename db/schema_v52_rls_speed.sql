-- ============================================================
-- YAK-TAG — schema patch v52
-- Faster reads: the access rules (RLS) ask "who is this?" once per
-- request instead of once per row.
--
-- The 2026-10-23 load test found the slow spot: a herder opening his
-- herd list (cattle_dashboard, 20 animals) took ~260 ms of database time
-- on a farm with 4,000 animals — the rules called is_super(), my_role(),
-- my_farm() and auth.uid() for EVERY row looked at (all 4,000 animals,
-- then again inside every milk / scan lookup). Wrapping each call as
-- (select …) lets Postgres work the answer out once per request — the
-- fix Supabase itself recommends.
--
-- Measured on the full local rebuild (v1 → v51 + this): herd list
-- 258 ms → 23 ms; 39 → 436 lists/second (10 at once), 46 → 858 (40 at once).
-- Who may see / change what is NOT changed: the same 141 role checks
-- (db/test/test_v49 / v50 / v51) pass before and after.
--
-- What it does: rewrites the text of every access rule in the public and
-- storage schemas, wrapping bare calls of the helper functions. Nothing
-- else, no rows touched. A rule Supabase doesn't let this account change
-- is skipped and named in the messages (it keeps working as before).
--
-- Safe on the live project and safe to run twice (already wrapped calls
-- are left alone). Nothing in the website or app needs to change.
-- ============================================================

do $$
begin
  if to_regprocedure('public.scan_caller_hash()') is null or to_regclass('public.public_scans') is null then
    raise exception 'Wrong database: this is not the YAK-TAG project (oxfbxqclqfglpzgzizhq). Open the right project and run again.';
  end if;
end $$;

do $$
declare
  r record; q text; c text; f text; pat text;
  n_done int := 0; n_skip int := 0;
  -- helper calls that give the same answer for every row of one request
  fns text[] := array['is_super()', 'is_admin()', 'my_role()', 'my_farm()', 'my_farm_live()',
                      'auth.uid()', 'auth.role()', 'auth.jwt()'];
begin
  for r in select schemaname, tablename, policyname, qual, with_check
             from pg_policies where schemaname in ('public', 'storage') loop
    q := r.qual; c := r.with_check;
    foreach f in array fns loop
      pat := '(?<!select )(' || regexp_replace(f, '([().])', '\\\1', 'g') || ')';   -- not already "(select f)"
      if q is not null then q := regexp_replace(q, pat, '(select \1)', 'gi'); end if;
      if c is not null then c := regexp_replace(c, pat, '(select \1)', 'gi'); end if;
    end loop;
    continue when q is not distinct from r.qual and c is not distinct from r.with_check;
    begin
      execute format('alter policy %I on %I.%I', r.policyname, r.schemaname, r.tablename)
           || case when q is not null then format(' using (%s)', q) else '' end
           || case when c is not null then format(' with check (%s)', c) else '' end;
      n_done := n_done + 1;
    exception when insufficient_privilege then
      n_skip := n_skip + 1;
      raise notice 'skipped (no permission, keeps working as before): %.% — %', r.schemaname, r.tablename, r.policyname;
    end;
  end loop;
  raise notice 'v52: % access rules sped up, % skipped', n_done, n_skip;
end $$;

-- ============================================================
-- CHECK (the result appears below after Run): access rules that still
-- call a helper once per row. Expected: none, or only rules named as
-- "skipped" in the messages.
-- ============================================================
select schemaname, tablename, policyname
  from pg_policies
 where schemaname in ('public', 'storage')
   and (coalesce(qual, '') || ' ' || coalesce(with_check, ''))
       ~* '(?<!select )(is_super|is_admin|my_role|my_farm|my_farm_live)\(\)|(?<!select )auth\.(uid|role|jwt)\(\)'
 order by 1, 2, 3;
