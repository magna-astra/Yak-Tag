#!/usr/bin/env python3
"""
YAK-TAG — check SUPABASE_DB_URL before the full backup (pg_dump).

Run by .github/workflows/backup.yml (job full-copy). It explains the usual
mistakes in plain words, as a red annotation on the run page, instead of
a bare "exit code 1". The password is never printed.

Env:  DB_URL   the secret SUPABASE_DB_URL
      PSQL     path to psql (default: psql)
Writes major=<server major version> to $GITHUB_OUTPUT.
"""

import os
import re
import subprocess
import sys
import urllib.parse as up

URL = (os.environ.get("DB_URL") or "").strip()
PSQL = os.environ.get("PSQL") or "psql"
WHERE = "Supabase → Connect → Session pooler"


def fail(title, msg):
    print(f"::error title={title}::{msg}")
    sys.exit(1)


def main():
    if not URL.startswith(("postgresql://", "postgres://")):
        fail("SUPABASE_DB_URL", f"It must start with postgresql:// — copy the URI from {WHERE}.")
    if "YOUR-PASSWORD" in URL.upper():
        fail("SUPABASE_DB_URL", "It still contains [YOUR-PASSWORD]. Replace it, brackets included, with the database password.")

    netloc = URL.split("://", 1)[1].split("/", 1)[0].split("?", 1)[0].split("#", 1)[0]
    if netloc.count("@") != 1:
        fail("SUPABASE_DB_URL", "The address cannot be read: the password probably contains @ / ? or #. "
             "Reset the database password to letters and digits only (Supabase → Project Settings → Database) "
             "and paste the new URI into the secret.")
    userinfo, hostport = netloc.rsplit("@", 1)
    user_raw, _, pw_raw = userinfo.partition(":")
    if re.search(r"%(?![0-9A-Fa-f]{2})", pw_raw):
        fail("SUPABASE_DB_URL", "The password contains a % sign that is not encoded. Use letters and digits only, or write % as %25.")
    password = up.unquote(pw_raw)
    secrets = {s for s in (pw_raw, password) if s}

    p = up.urlsplit(URL)
    try:
        host, port = p.hostname or "", p.port or 5432
    except ValueError:
        fail("SUPABASE_DB_URL", f"The port is not a number. Copy the URI again from {WHERE}.")
    user = up.unquote(user_raw)
    print(f"host={host} port={port} user={user} (password hidden)")

    if host.startswith("db.") and host.endswith(".supabase.co"):
        fail("SUPABASE_DB_URL", f"This is the DIRECT connection: it works over IPv6 only and GitHub cannot reach it. Use {WHERE} (port 5432).")
    if port == 6543:
        fail("SUPABASE_DB_URL", f"Port 6543 is the TRANSACTION pooler; pg_dump needs the SESSION pooler (port 5432). Use {WHERE}.")
    if "pooler.supabase.com" in host and "." not in user:
        fail("SUPABASE_DB_URL", "Through the pooler the user must be postgres.<project-ref> (for example postgres.oxfbxqclqfglpzgzizhq), exactly as Supabase shows it.")

    try:
        r = subprocess.run([PSQL, URL, "-X", "-At", "-c", "show server_version_num"],
                           capture_output=True, text=True, timeout=90)
    except subprocess.TimeoutExpired:
        fail("Cannot connect", "No answer from the database within 90 seconds.")
    if r.returncode != 0:
        err = r.stderr.strip()
        for s in secrets:
            err = err.replace(s, "***")
        low = err.lower()
        if "password authentication failed" in low:
            hint = "Wrong database password in the URI. Reset it (Supabase → Project Settings → Database) and update the secret."
        elif "tenant or user not found" in low:
            hint = f"The pooler does not know this user/region. Copy the URI again from {WHERE}; the user must be postgres.<project-ref>."
        elif "network is unreachable" in low or "could not translate host name" in low:
            hint = f"The host cannot be reached. Use {WHERE}, not the direct connection."
        elif "timeout" in low or "timed out" in low:
            hint = "The connection timed out. Is the Supabase project paused?"
        else:
            hint = "See the message."
        fail("Cannot connect", f"{hint} — {' '.join(err.split())[:500]}")

    num = int(r.stdout.strip().splitlines()[-1])
    major = num // 10000
    print(f"Connected. Server version {major} ({num}).")
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a", encoding="utf-8") as f:
            f.write(f"major={major}\n")


if __name__ == "__main__":
    main()
