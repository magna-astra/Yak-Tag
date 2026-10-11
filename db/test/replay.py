# Replays db/schema.sql + seed.sql + every schema_vNN patch, in order, on a
# throwaway local Postgres 18 with Supabase stand-ins (stub.sql) and the
# objects that were made by hand on live (prelude.sql). Reports what fails.
#   python db/test/replay.py [--keep] [extra.sql ...]
# --keep leaves it running on port 55440; then run the role tests:
#   PGCLIENTENCODING=UTF8 psql -p 55440 -U postgres -d postgres -f db/test/test_v49.sql
# (one transaction, rolled back at the end, so they can be run again).
import os, re, subprocess, sys, shutil, tempfile

PG = r'C:\Program Files\PostgreSQL\18\bin'
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..'))
PORT = '55440'
DATA = os.path.join(os.environ['TEMP'], 'yt-replay')
ENV = dict(os.environ, PGCLIENTENCODING='UTF8')
keep = '--keep' in sys.argv
extra = [a for a in sys.argv[1:] if a.endswith('.sql')]

def pg(*args, **kw):
    return subprocess.run([os.path.join(PG, args[0]), *args[1:]], capture_output=True, text=True, env=ENV, **kw)

def psql_file(path, label=None):
    sys.stdout.flush()
    r = pg('psql.exe', '-X', '-q', '-p', PORT, '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-f', path)
    ok = r.returncode == 0
    msg = (r.stderr or '').strip().splitlines()
    errs = [m for m in msg if 'ERROR' in m or 'FATAL' in m]
    print(f"{'ok  ' if ok else 'FAIL'} {label or os.path.basename(path)}" + ('' if ok else '  ' + ' | '.join(errs)[:400]))
    return ok

def main():
    if os.path.exists(DATA):
        subprocess.run([os.path.join(PG, 'pg_ctl.exe'), '-D', DATA, '-w', 'stop'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        shutil.rmtree(DATA, ignore_errors=True)
    pg('initdb.exe', '-U', 'postgres', '-E', 'UTF8', '--locale=C', '-D', DATA)
    # the server inherits pipes; capturing them would wait forever on Windows
    r = subprocess.run([os.path.join(PG, 'pg_ctl.exe'), '-D', DATA, '-o', f'-p {PORT}', '-l', os.path.join(DATA, 'log'),
                        '-w', '-t', '60', 'start'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=ENV)
    if r.returncode: print('server did not start'); sys.exit(1)
    psql_file(os.path.join(HERE, 'stub.sql'), 'supabase stand-ins')
    db = os.path.join(REPO, 'db')
    vers = sorted([f for f in os.listdir(db) if re.match(r'schema_v\d+_.*\.sql$', f)],
                  key=lambda f: int(re.search(r'v(\d+)', f).group(1)))
    order = ['schema.sql', 'seed.sql'] + vers
    tmp = tempfile.mkdtemp()
    fails = []
    for f in order:
        src = open(os.path.join(db, f), encoding='utf-8').read()
        src = re.sub(r'create extension if not exists pg_net\s*;', '-- (pg_net stubbed)', src, flags=re.I)
        p = os.path.join(tmp, f); open(p, 'w', encoding='utf-8').write(src)
        if not psql_file(p, f): fails.append(f)
        if f == 'seed.sql':
            psql_file(os.path.join(HERE, 'prelude.sql'), 'prelude (objects made by hand on live)')
    for e in extra:
        if not psql_file(e): fails.append(os.path.basename(e))
    print('\nFAILED:', fails or 'none')
    if not keep:
        subprocess.run([os.path.join(PG, 'pg_ctl.exe'), '-D', DATA, '-w', 'stop'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        shutil.rmtree(DATA, ignore_errors=True)
    else:
        print(f'kept running on port {PORT} (data {DATA})')

main()
