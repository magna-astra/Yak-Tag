-- ============================================================
-- YAK-TAG — security audit
-- Read-only. Run any time. Every result has an expected value.
-- ============================================================

-- 1. RLS must be ON for every table. Any "false" is a hole.
select '1. RLS ENABLED — all must be true' as check;
select tablename, rowsecurity
from pg_tables where schemaname='public'
order by rowsecurity, tablename;

-- 2. Every table needs at least one policy. RLS on with no policy
--    means nobody can read it; RLS off with data means everybody can.
select '2. TABLES WITHOUT POLICIES' as check;
select t.tablename
from pg_tables t
left join pg_policies p on p.tablename=t.tablename and p.schemaname='public'
where t.schemaname='public'
group by t.tablename
having count(p.policyname)=0;

-- 3. Views must run as the caller, not the owner. "false" here was
--    the original leak that let every farm see every animal.
select '3. VIEW security_invoker — all must be true' as check;
select c.relname,
       coalesce((select option_value='true' from pg_options_to_table(c.reloptions)
                  where option_name='security_invoker'), false) as security_invoker
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where c.relkind='v' and n.nspname='public' order by 2, 1;

-- 4. What anonymous callers can execute. Each one is an open door;
--    there should be exactly three.
select '4. FUNCTIONS ANON CAN CALL' as check;
select p.proname, pg_get_function_identity_arguments(p.oid) as args
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and has_function_privilege('anon', p.oid, 'EXECUTE')
order by p.proname;

-- 5. security definer functions bypass RLS by design. Each must
--    check permissions itself. Review any that do not.
select '5. SECURITY DEFINER FUNCTIONS' as check;
select p.proname,
       (p.prosrc like '%is_super()%' or p.prosrc like '%my_role()%'
        or p.prosrc like '%my_farm()%' or p.prosrc like '%auth.uid()%') as has_auth_check
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.prosecdef
order by 2, 1;

-- 6. Storage policies. cattle-photos must be farm-scoped;
--    cattle-public may be open for read only.
select '6. STORAGE POLICIES' as check;
select policyname, cmd, roles::text,
       coalesce(qual, with_check) as rule
from pg_policies where schemaname='storage' and tablename='objects'
order by policyname;

-- 7. Buckets: cattle-photos MUST be private.
select '7. BUCKETS' as check;
select name, public,
       case when name='cattle-photos' and public then 'WRONG — must be private'
            when name='cattle-public' and not public then 'WRONG — must be public'
            else 'ok' end as verdict
from storage.buckets order by name;

-- 8. Signs of a tag-enumeration sweep.
select '8. LOOKUP ABUSE (empty is good)' as check;
select * from lookup_abuse limit 10;

-- 9. Scan volume — a spike means flooding.
select '9. SCAN VOLUME, LAST 24H' as check;
select date_trunc('hour', scanned_at) as hour, count(*) as scans
from public_scans where scanned_at > now() - interval '24 hours'
group by 1 order by 1 desc;

-- 10. Table sizes — free tier is 500 MB.
select '10. TABLE SIZES' as check;
select relname, pg_size_pretty(pg_total_relation_size(c.oid)) as size,
       (select reltuples::bigint from pg_class where oid=c.oid) as approx_rows
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relkind='r'
order by pg_total_relation_size(c.oid) desc limit 15;
