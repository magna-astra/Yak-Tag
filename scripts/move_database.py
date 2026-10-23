#!/usr/bin/env python3
"""
YAK-TAG — move the database to another Supabase project (e.g. Sydney → Tokyo).

    python scripts/move_database.py check     # both projects reachable? new one ready?
    python scripts/move_database.py copy      # database: tables, rules, functions, data,
                                              #   logins (same ids + password hashes),
                                              #   photo buckets + photo access rules
    python scripts/move_database.py copy --fresh   # first wipe what an earlier copy put
                                              #   into the NEW project, then copy again
    python scripts/move_database.py photos    # every photo file, old → new (only missing /
                                              #   changed ones; safe to run again)
    python scripts/move_database.py verify    # row counts old vs new, table by table
    python scripts/move_database.py move      # all four in one go (secrets asked once)

The OLD project is only ever READ. Nothing is written to it.
Refuses to write into the project the website uses now (the address in
config.js), so the live database can never be wiped by mistake.

Asks, each run, in this window (nothing is saved, passwords never shown):
  · each project's "Session pooler" connection string, exactly as Supabase
    shows it (Connect → Session pooler), WITH the [YOUR-PASSWORD] text in it,
  · then each database password at a hidden prompt,
  · for `photos`: each project's secret key (sb_secret_… / service_role).
Needs PostgreSQL 17+ client tools (pg_dump, psql) — C:\\Program Files\\PostgreSQL\\18\\bin.
For tests, YT_OLD_DB / YT_NEW_DB (full connection strings) and
YT_OLD_URL / YT_NEW_URL / YT_OLD_KEY / YT_NEW_KEY may be set instead.
"""

import getpass
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, ".."))
PG_BIN = os.environ.get("PG_BIN") or (r"C:\Program Files\PostgreSQL\18\bin" if os.name == "nt" else "")
BUCKETS = ["cattle-photos", "cattle-public"]
PAGE = 1000
# add-ons the new project needs (tests on a plain local Postgres override this)
NEED_EXT = (os.environ.get("YT_NEED_EXT") or "pgcrypto,btree_gist,pg_net").split(",")


def tool(name):
    exe = os.path.join(PG_BIN, name + (".exe" if os.name == "nt" else "")) if PG_BIN else name
    return exe if (not PG_BIN or os.path.exists(exe)) else name


def live_ref():
    """The project the website uses right now (config.js)."""
    m = re.search(r"https://([a-z0-9]+)\.supabase\.co", open(os.path.join(REPO, "config.js"), encoding="utf-8").read())
    return m.group(1) if m else None


# ---------------------------------------------------------------- connections
class Conn:
    def __init__(self, label, env_db):
        self.label = label
        raw = os.environ.get(env_db)
        if not raw:
            # YT_OLD_DB_POOLER / YT_NEW_DB_POOLER: the string as Supabase shows it,
            # [YOUR-PASSWORD] included (no secret) — then only the password is asked
            raw = os.environ.get(env_db + "_POOLER", "").strip()
            if raw:
                print(f"\n{label.upper()} project: {raw}")
            else:
                print(f"\n{label.upper()} project — Connect → Session pooler → copy the connection string")
                print("(paste it exactly as shown, with [YOUR-PASSWORD] still in it)")
                raw = input("  connection string: ").strip()
            if "[YOUR-PASSWORD]" not in raw:
                sys.exit("  It must still contain [YOUR-PASSWORD] — the password is typed separately, hidden. Run again.")
            pw = getpass.getpass(f"  {label} database password (hidden): ")
            raw = raw.replace("[YOUR-PASSWORD]", urllib.parse.quote(pw, safe=""))
        u = urllib.parse.urlparse(raw)
        if u.scheme not in ("postgres", "postgresql") or not u.hostname:
            sys.exit(f"  {label}: that is not a postgresql:// connection string.")
        self.host, self.port = u.hostname, str(u.port or 5432)
        self.user = urllib.parse.unquote(u.username or "postgres")
        self.password = urllib.parse.unquote(u.password or "")
        self.db = (u.path or "/postgres").lstrip("/") or "postgres"
        # project ref: pooler user is postgres.<ref>; a direct host is db.<ref>.supabase.co
        m = re.match(r"postgres\.([a-z0-9]+)$", self.user) or re.match(r"db\.([a-z0-9]+)\.supabase\.co$", self.host)
        self.ref = m.group(1) if m else None

    def env(self):
        return dict(os.environ, PGPASSWORD=self.password, PGCLIENTENCODING="UTF8", PGCONNECT_TIMEOUT="20")

    def args(self):
        return ["-h", self.host, "-p", self.port, "-U", self.user, "-d", self.db]

    def sql(self, query):
        """One query → list of rows (tab-separated text)."""
        r = subprocess.run([tool("psql"), "-X", "-q", "-A", "-t", "-F", "\t", "-v", "ON_ERROR_STOP=1",
                            *self.args(), "-c", query], capture_output=True, text=True, encoding="utf-8", env=self.env())
        if r.returncode:
            raise RuntimeError(f"{self.label}: {r.stderr.strip()[:400]}")
        return [line.split("\t") for line in r.stdout.splitlines() if line.strip()]

    def json(self, query):
        """A query returning ONE json value (psql may print it over several lines)."""
        r = subprocess.run([tool("psql"), "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1",
                            *self.args(), "-c", query], capture_output=True, text=True, encoding="utf-8", env=self.env())
        if r.returncode:
            raise RuntimeError(f"{self.label}: {r.stderr.strip()[:400]}")
        return json.loads(r.stdout)


def project_url(conn, env_url):
    if os.environ.get(env_url):
        return os.environ[env_url].rstrip("/")
    if not conn.ref:
        sys.exit(f"{conn.label}: can't tell the project from the connection string — use the Session pooler one.")
    return f"https://{conn.ref}.supabase.co"


def guard_new(old, new):
    if old.ref and new.ref and old.ref == new.ref:
        sys.exit("OLD and NEW are the same project. Nothing done.")
    live = live_ref()
    if new.ref and live and new.ref == live:
        sys.exit(f"NEW ({new.ref}) is the project the website uses NOW (config.js). Refusing to write into it.")


# ---------------------------------------------------------------- check
def cmd_check(old, new):
    for c in (old, new):
        v = c.sql("select current_setting('server_version')")[0][0]
        print(f"  {c.label}: reachable, PostgreSQL {v}, project {c.ref or '?'}")
    have = {r[0] for r in new.sql("select extname from pg_extension")}
    missing = [e for e in NEED_EXT if e not in have]
    print("  new: add-ons " + ("all present" if not missing else "MISSING " + ", ".join(missing) +
                                " — run the 3 'create extension' lines in its SQL Editor"))
    n_new = int(new.sql("select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace "
                        "where n.nspname = 'public' and c.relkind in ('r','v','m')")[0][0])
    n_old = int(old.sql("select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace "
                        "where n.nspname = 'public' and c.relkind in ('r','v','m')")[0][0])
    print(f"  old: {n_old} tables/views in public; new: {n_new}" + (" (empty — ready)" if n_new == 0 else " (has data — use copy --fresh)"))
    users_old = old.sql("select count(*) from auth.users")[0][0]
    users_new = new.sql("select count(*) from auth.users")[0][0]
    print(f"  old: {users_old} logins; new: {users_new}")
    guard_new(old, new)
    return not missing


# ---------------------------------------------------------------- copy (database)
DROP_LINES = [
    re.compile(r"^CREATE SCHEMA (public|\"public\");"),
    re.compile(r"^COMMENT ON SCHEMA (public|\"public\")"),
    re.compile(r"^ALTER DEFAULT PRIVILEGES FOR ROLE \"?supabase_admin\"?"),
    re.compile(r"OWNER TO \"?supabase_admin\"?;"),
    re.compile(r"^SET transaction_timeout"),          # not known to every server version
]


def clean_dump(path):
    out, dropped = [], 0
    with open(path, encoding="utf-8") as f:
        for line in f:
            if any(p.search(line) for p in DROP_LINES):
                dropped += 1
                continue
            out.append(line)
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(out)
    return dropped


def lit(s):
    return "null" if s is None else "'" + str(s).replace("'", "''") + "'"


def storage_sql(old):
    """Buckets (with their limits) and the access rules on storage.objects."""
    out = ["-- photo buckets and photo access rules (from the old project)"]
    # read as one JSON value: rule texts can run over several lines
    buckets = old.json("select coalesce(json_agg(json_build_object('id', id, 'name', name, 'public', public, "
                       "'lim', file_size_limit, 'mimes', allowed_mime_types) order by id), '[]') "
                       "from storage.buckets")
    for bk in buckets:
        mt = "null" if not bk["mimes"] else "array[" + ", ".join(lit(m) for m in bk["mimes"]) + "]::text[]"
        out.append(f"insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values "
                   f"({lit(bk['id'])}, {lit(bk['name'])}, {str(bool(bk['public'])).lower()}, "
                   f"{bk['lim'] if bk['lim'] is not None else 'null'}, {mt}) on conflict (id) do update set "
                   f"public = excluded.public, file_size_limit = excluded.file_size_limit, "
                   f"allowed_mime_types = excluded.allowed_mime_types;")
    # deparse with an empty search_path so every function name comes out schema-qualified
    pols = old.json("set search_path to ''; select coalesce(json_agg(json_build_object('name', policyname, "
                    "'permissive', permissive, 'cmd', cmd, 'roles', roles, 'qual', qual, 'check', with_check) "
                    "order by policyname), '[]') from pg_policies "
                    "where schemaname = 'storage' and tablename = 'objects'")
    rows = [(p["name"], p["permissive"], p["cmd"], p["roles"], p["qual"] or "", p["check"] or "") for p in pols]
    for name, permissive, cmd, roles, qual, check in rows:
        rl = ", ".join('"%s"' % r if r != "public" else "public" for r in roles)
        out.append(f'drop policy if exists "{name}" on storage.objects;')
        out.append(f'create policy "{name}" on storage.objects as {permissive.lower()} for {cmd.lower()} to {rl}'
                   + (f" using ({qual})" if qual else "") + (f" with check ({check})" if check else "") + ";")
    return "\n".join(out) + "\n", len(rows)


WIPE_SQL = r"""
-- remove what an earlier copy put into the NEW project (public schema objects + logins)
do $$
declare r record;
begin
  for r in select format('drop view if exists %I.%I cascade', schemaname, viewname) s from pg_views where schemaname = 'public'
    union all select format('drop materialized view if exists %I.%I cascade', schemaname, matviewname) from pg_matviews where schemaname = 'public'
    union all select format('drop table if exists %I.%I cascade', schemaname, tablename) from pg_tables where schemaname = 'public'
  loop execute r.s; end loop;
  for r in select format('drop %s if exists %s cascade', case p.prokind when 'p' then 'procedure' when 'a' then 'aggregate' else 'function' end,
                         p.oid::regprocedure) s
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop execute r.s; end loop;
  for r in select format('drop sequence if exists %I.%I cascade', sequence_schema, sequence_name) s
             from information_schema.sequences where sequence_schema = 'public'
  loop execute r.s; end loop;
  for r in select format('drop type if exists %I.%I cascade', n.nspname, t.typname) s
             from pg_type t join pg_namespace n on n.oid = t.typnamespace
            where n.nspname = 'public' and t.typtype in ('e', 'd', 'c')
              and not exists (select 1 from pg_class c where c.oid = t.typrelid and c.relkind <> 'c')
              and not exists (select 1 from pg_depend d where d.objid = t.oid and d.deptype = 'e')
  loop execute r.s; end loop;
end $$;
delete from auth.users;
"""


# Every object must get EXACTLY the permissions it had in the old project.
# A new Supabase project grants anon / authenticated / service_role all
# rights on every new table, function and sequence in public (its "default
# privileges"); pg_dump only re-applies differences from Postgres' own
# defaults, so those automatic grants would silently undo our lock-downs
# (v37, v46…). Switch them off while loading — the dump re-creates the old
# project's own default privileges at its end, and global ones are copied
# separately (global_defaults_sql).
PRE_SQL = """
alter default privileges for role postgres in schema public revoke all on tables    from anon, authenticated, service_role;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated, service_role;
alter default privileges for role postgres in schema public revoke all on functions from anon, authenticated, service_role;
alter default privileges for role postgres revoke all on tables    from anon, authenticated, service_role;
alter default privileges for role postgres revoke all on sequences from anon, authenticated, service_role;
alter default privileges for role postgres revoke all on functions from anon, authenticated, service_role;
"""

OBJ = {"r": "tables", "S": "sequences", "f": "functions", "T": "types", "n": "schemas"}


def global_defaults_sql(old):
    """The old project's default privileges that apply in every schema (role postgres)."""
    rows = old.json("select coalesce(json_agg(json_build_object('t', d.defaclobjtype, 'g', case when a.grantee = 0 "
                    "then 'public' else a.grantee::regrole::text end, 'p', a.privilege_type)), '[]') "
                    "from pg_default_acl d, aclexplode(d.defaclacl) a "
                    "where d.defaclrole = 'postgres'::regrole and d.defaclnamespace = 0")
    out = ["-- default privileges of role postgres that apply in every schema (as in the old project)"]
    for r in rows:
        if r["t"] in OBJ and r["g"] != "postgres":
            out.append(f'alter default privileges for role postgres grant {r["p"]} on {OBJ[r["t"]]} to {r["g"]};')
    return "\n".join(out) + "\n"


def run_psql_files(conn, files, replica=True):
    cmd = [tool("psql"), "-X", "-q", "-v", "ON_ERROR_STOP=1", "--single-transaction", *conn.args()]
    if replica:
        cmd += ["-c", "set session_replication_role = replica"]   # no triggers (no alerts) while loading
    for f in files:
        cmd += ["-f", f]
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", env=conn.env())
    return r.returncode, (r.stderr or "").strip()


def cmd_copy(old, new, fresh=False, keep_files=False):
    guard_new(old, new)
    have = {r[0] for r in new.sql("select extname from pg_extension")}
    missing = [e for e in NEED_EXT if e not in have]
    if missing:
        sys.exit("NEW project is missing add-ons: " + ", ".join(missing) + " — run the 'create extension' lines first.")
    n_new = int(new.sql("select count(*) from pg_tables where schemaname = 'public'")[0][0])
    n_new += int(new.sql("select count(*) from auth.users")[0][0])          # logins count as "not empty" too
    if n_new and not fresh:
        sys.exit(f"NEW project is not empty (tables or logins). To replace them with a fresh copy: copy --fresh")
    if fresh and n_new:
        print(f"\nThis WIPES the tables, functions and logins in the NEW project {new.ref} before copying again.")
        if input(f"  Type the NEW project id ({new.ref}) to confirm: ").strip() != (new.ref or ""):
            sys.exit("  Not confirmed — nothing done.")

    work = tempfile.mkdtemp(prefix="yaktag-move-")
    try:
        t0 = time.time()
        pub, auth, sto, wipe = (os.path.join(work, n) for n in ("public.sql", "auth.sql", "storage.sql", "wipe.sql"))
        print("\n1/4 reading the old database (tables, rules, functions, data)…")
        r = subprocess.run([tool("pg_dump"), *old.args(), "--schema=public", "--no-owner", "--no-subscriptions",
                            "--no-publications", "--no-security-labels", "-f", pub],
                           capture_output=True, text=True, encoding="utf-8", env=old.env())
        if r.returncode:
            sys.exit("pg_dump (public) failed: " + r.stderr.strip()[:600])
        dropped = clean_dump(pub)
        print("2/4 reading the logins (same ids and password hashes)…")
        r = subprocess.run([tool("pg_dump"), *old.args(), "--data-only", "--no-owner",
                            "--table=auth.users", "--table=auth.identities", "-f", auth],
                           capture_output=True, text=True, encoding="utf-8", env=old.env())
        if r.returncode:
            sys.exit("pg_dump (logins) failed: " + r.stderr.strip()[:600])
        clean_dump(auth)
        text, n_pol = storage_sql(old)
        with open(sto, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"3/4 photo buckets + {n_pol} photo access rules prepared"
              f" ({os.path.getsize(pub) // 1024} KB of tables, {dropped} Supabase-internal lines left out)")

        files = []
        if fresh and n_new:
            with open(wipe, "w", encoding="utf-8") as f:
                f.write(WIPE_SQL)
            files.append(wipe)
        pre, post = os.path.join(work, "pre.sql"), os.path.join(work, "defaults.sql")
        with open(pre, "w", encoding="utf-8") as f:
            f.write(PRE_SQL)
        with open(post, "w", encoding="utf-8") as f:
            f.write(global_defaults_sql(old))
        files += [pre, auth, pub, sto, post]
        print("4/4 writing into the NEW project — all or nothing (one transaction)…")
        rc, err = run_psql_files(new, files)
        if rc:
            print("\nFAILED — the NEW project was left exactly as before (nothing kept). The error:")
            print("  " + "\n  ".join(err.splitlines()[-12:]))
            sys.exit(1)
        new.sql("notify pgrst, 'reload schema'")
        print(f"\nDone in {time.time() - t0:.0f} s. Next: python scripts/move_database.py verify")
    finally:
        if keep_files:
            print(f"(files kept in {work} — they contain personal data: delete the folder afterwards)")
        else:
            shutil.rmtree(work, ignore_errors=True)     # the copy holds personal data: never leave it lying around


# ---------------------------------------------------------------- verify
def counts(conn):
    rows = conn.sql("select table_name from information_schema.tables where table_schema = 'public' "
                    "and table_type = 'BASE TABLE' order by 1")
    out = {}
    for (t,) in rows:
        out[t] = int(conn.sql(f'select count(*) from public."{t}"')[0][0])
    out["(logins) auth.users"] = int(conn.sql("select count(*) from auth.users")[0][0])
    out["(photo rules) storage.objects policies"] = int(conn.sql(
        "select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects'")[0][0])
    out["(access rules) public policies"] = int(conn.sql("select count(*) from pg_policies where schemaname = 'public'")[0][0])
    out["(functions) public"] = int(conn.sql("select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace "
                                             "where n.nspname = 'public' and not exists (select 1 from pg_depend d "
                                             "where d.objid = p.oid and d.deptype = 'e')")[0][0])   # not add-on functions
    return out


def permissions(conn):
    """Who may do what: every table/view/sequence and function in public, the
    default privileges of role postgres, and the text of every access rule."""
    return conn.json("""
      select json_build_object(
        'objects', (select coalesce(json_object_agg(c.relkind::text || ' ' || c.relname, coalesce(c.relacl::text, '')), '{}')
                      from pg_class c join pg_namespace n on n.oid = c.relnamespace
                     where n.nspname = 'public' and c.relkind in ('r', 'v', 'm', 'S')),
        'functions', (select coalesce(json_object_agg(p.oid::regprocedure::text, coalesce(p.proacl::text, '')), '{}')
                        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                       where n.nspname = 'public'
                         and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')),
        'defaults', (select coalesce(json_object_agg(coalesce(defaclnamespace::regnamespace::text, '(all)') || ' ' || defaclobjtype::text,
                                                     defaclacl::text), '{}')
                       from pg_default_acl where defaclrole = 'postgres'::regrole),
        'rules', (select coalesce(json_object_agg(schemaname || '.' || tablename || ' ' || policyname,
                                                  md5(permissive || cmd || roles::text || coalesce(qual, '') || coalesce(with_check, ''))), '{}')
                    from pg_policies where schemaname in ('public', 'storage')))
    """)


def cmd_verify(old, new):
    a, b = counts(old), counts(new)
    bad = 0
    pa, pb = permissions(old), permissions(new)
    for part, label in (("objects", "table permissions"), ("functions", "function permissions"),
                        ("defaults", "automatic grants"), ("rules", "access rule texts")):
        diff = sorted(k for k in set(pa[part]) | set(pb[part]) if pa[part].get(k) != pb[part].get(k))
        a[f"({label}) differing"], b[f"({label}) differing"] = 0, len(diff)
        for k in diff[:8]:
            print(f"  DIFFERENT {label}: {k}\n      old {pa[part].get(k)}\n      new {pb[part].get(k)}")
    print(f"\n  {'':44} {'old':>8} {'new':>8}")
    for k in sorted(set(a) | set(b)):
        same = a.get(k) == b.get(k)
        bad += 0 if same else 1
        print(f"  {k:44} {str(a.get(k, '—')):>8} {str(b.get(k, '—')):>8}  {'ok' if same else 'DIFFERENT'}")
    print("\n  All the same." if not bad else f"\n  {bad} line(s) differ — see above.")
    return bad == 0


# ---------------------------------------------------------------- photos
def api(url, key, method, path, body=None, data=None, headers=None):
    h = {"apikey": key, "Authorization": f"Bearer {key}", **(headers or {})}
    if body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(url + path, data=data, method=method, headers=h)
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read(), r.headers


def list_files(url, key, bucket, prefix=""):
    """{path: (size, mimetype)} of every file in a bucket, all folders deep."""
    files, offset = {}, 0
    while True:
        raw, _ = api(url, key, "POST", f"/storage/v1/object/list/{bucket}",
                     body={"prefix": prefix, "limit": PAGE, "offset": offset, "sortBy": {"column": "name", "order": "asc"}})
        page = json.loads(raw.decode())
        for e in page:
            name = e.get("name") or ""
            if not name or name == ".emptyFolderPlaceholder":
                continue
            path = f"{prefix}/{name}" if prefix else name
            if e.get("id") is None:
                files.update(list_files(url, key, bucket, path))
            else:
                md = e.get("metadata") or {}
                files[path] = (int(md.get("size") or -1), md.get("mimetype") or "image/jpeg")
        if len(page) < PAGE:
            return files
        offset += len(page)


def quoted(path):
    return "/".join(urllib.parse.quote(p, safe="") for p in path.split("/"))


def get_keys():
    ok_ = os.environ.get("YT_OLD_KEY") or getpass.getpass("\n  OLD project secret key (sb_secret_… / service_role, hidden): ")
    nk = os.environ.get("YT_NEW_KEY") or getpass.getpass("  NEW project secret key (sb_secret_… / service_role, hidden): ")
    return ok_.strip(), nk.strip()


def cmd_photos(old, new, keys=None):
    guard_new(old, new)
    ou, nu = project_url(old, "YT_OLD_URL"), project_url(new, "YT_NEW_URL")
    ok_, nk = keys or get_keys()
    problems = 0
    for b in BUCKETS:
        src = list_files(ou, ok_, b)
        try:
            dst = list_files(nu, nk, b)
        except urllib.error.HTTPError:
            dst = {}
        copied = same = failed = 0
        size = 0
        for path, (sz, mime) in sorted(src.items()):
            if path in dst and dst[path][0] == sz:
                same += 1
                continue
            try:
                data, _ = api(ou, ok_, "GET", f"/storage/v1/object/{b}/{quoted(path)}")
                api(nu, nk, "POST", f"/storage/v1/object/{b}/{quoted(path)}", data=data,
                    headers={"Content-Type": mime, "x-upsert": "true", "cache-control": "3600"})
                copied += 1
                size += len(data)
            except Exception as e:
                failed += 1
                print(f"    {b}/{path}: FAILED ({e})")
        problems += failed
        print(f"  {b}: {len(src)} photos — {copied} copied ({size / 1048576:.1f} MB), {same} already there, {failed} failed")
    print("\n  All photos are in the new project." if not problems else f"\n  {problems} photo(s) failed — run photos again.")
    return problems == 0


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("check", "copy", "photos", "verify", "move"):
        print(__doc__)
        return
    cmd = sys.argv[1]
    old = Conn("old", "YT_OLD_DB")
    new = Conn("new", "YT_NEW_DB")
    try:
        if cmd == "move":
            # everything in one go, secrets asked once: check → database → photos → compare
            keys = get_keys()
            # from here on, everything printed is also written to a log file (no secret is
            # ever printed), so the result can be read without looking at this window
            log = os.path.join(tempfile.gettempdir(), "yaktag-move-log.txt")

            class Tee:
                def __init__(self, *s): self.s = s
                def write(self, x):
                    for s in self.s: s.write(x); s.flush()
                def flush(self):
                    for s in self.s: s.flush()
            sys.stdout = Tee(sys.__stdout__, open(log, "w", encoding="utf-8"))
            print(f"(progress also written to {log})")
            print("\n=== 1. check ===")
            if not cmd_check(old, new):
                sys.exit("Fix the add-ons first, then run move again.")
            print("\n=== 2. database ===")
            cmd_copy(old, new, fresh="--fresh" in sys.argv)
            print("\n=== 3. photos ===")
            photos_ok = cmd_photos(old, new, keys)
            print("\n=== 4. compare old and new ===")
            same = cmd_verify(old, new)
            print("\nMOVE COPY " + ("COMPLETE — everything matches." if same and photos_ok else "NOT complete — see above."))
            sys.exit(0 if same and photos_ok else 1)
        if cmd == "check":
            sys.exit(0 if cmd_check(old, new) else 1)
        if cmd == "copy":
            cmd_copy(old, new, fresh="--fresh" in sys.argv, keep_files="--keep-files" in sys.argv)
        if cmd == "verify":
            sys.exit(0 if cmd_verify(old, new) else 1)
        if cmd == "photos":
            sys.exit(0 if cmd_photos(old, new) else 1)
    except RuntimeError as e:
        sys.exit(str(e))


if __name__ == "__main__":
    main()
