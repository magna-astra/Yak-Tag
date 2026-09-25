#!/usr/bin/env python3
"""
YAK-TAG — export every table through the Supabase REST API.

Why not pg_dump: Supabase's direct database connection is IPv6-only and
GitHub Actions runners are IPv4-only, so psql can never connect from CI.
The REST API works over IPv4.

Together with db/schema.sql (structure) these JSON files are a full
restore path.

Env: SUPABASE_URL, SUPABASE_SERVICE_KEY
Usage: python3 scripts/export_supabase.py backups/2026-09-25
"""

import gzip
import json
import os
import sys
import urllib.error
import urllib.request

TABLES = [
    "farms", "profiles", "tag_batches", "tags", "cattle",
    "cattle_photos", "scan_events", "ownership_transfers",
    "health_events", "audit_log", "heartbeat",
]

PAGE = 1000

URL = (os.environ.get("SUPABASE_URL") or "").rstrip("/")
KEY = os.environ.get("SUPABASE_SERVICE_KEY") or ""


def fetch(table, offset):
    req = urllib.request.Request(
        f"{URL}/rest/v1/{table}?select=*&limit={PAGE}&offset={offset}",
        headers={
            "apikey": KEY,
            "Authorization": f"Bearer {KEY}",
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())


def export(table, outdir):
    rows, offset = [], 0
    while True:
        try:
            page = fetch(table, offset)
        except urllib.error.HTTPError as e:
            print(f"::warning::{table} HTTP {e.code} — skipped")
            return None
        except Exception as e:
            print(f"::warning::{table} failed: {e}")
            return None

        rows.extend(page)
        if len(page) < PAGE:
            break
        offset += PAGE

    path = os.path.join(outdir, f"{table}.json.gz")
    with gzip.open(path, "wt", encoding="utf-8") as f:
        json.dump(rows, f, ensure_ascii=False, indent=1, default=str)

    print(f"  {table}: {len(rows)} rows")
    return len(rows)


def main():
    if not URL or not KEY:
        print("::error::SUPABASE_URL or SUPABASE_SERVICE_KEY not set")
        sys.exit(1)

    outdir = sys.argv[1] if len(sys.argv) > 1 else "backups/manual"
    os.makedirs(outdir, exist_ok=True)

    ok, failed, total = 0, 0, 0
    for t in TABLES:
        n = export(t, outdir)
        if n is None:
            failed += 1
        else:
            ok += 1
            total += n

    with open(os.path.join(outdir, "README.txt"), "w", encoding="utf-8") as f:
        f.write(
            f"YAK-TAG backup\n"
            f"Tables exported: {ok} of {len(TABLES)}\n"
            f"Total rows: {total}\n\n"
            f"Restore:\n"
            f"  1. Run db/schema.sql on a fresh Supabase project\n"
            f"  2. Import each .json.gz into its matching table\n"
        )

    print(f"\nExported {ok}/{len(TABLES)} tables, {total} rows total.")

    if failed > 3:
        print(f"::error::{failed} tables failed")
        sys.exit(1)


if __name__ == "__main__":
    main()
