#!/usr/bin/env python3
"""
YAK-TAG — export every table through the Supabase REST API.

Why not pg_dump: Supabase's direct database connection is IPv6-only and
GitHub Actions runners are IPv4-only, so psql can never connect from CI.
The REST API works over IPv4.

This is the table DATA. The full copy (structure, rules, functions and
logins too) is database.dump, made by the workflow's pg_dump job through
Supabase's IPv4 session pooler once the SUPABASE_DB_URL secret is set.

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
    # added later: milk, pregnancy / calving, breeds, strangers' taps
    "milk_yield", "repro_events", "repro_calves", "breeds", "public_scans",
    # website orders and contact details (v41, v43). app_secrets is left
    # out on purpose: the Telegram token must never land in a backup.
    "order_requests", "site_settings",
    # who gets Telegram alerts (v38) — otherwise everyone re-links after a restore
    "telegram_links",
]

PAGE = 1000

URL = (os.environ.get("SUPABASE_URL") or "").rstrip("/")
KEY = os.environ.get("SUPABASE_SERVICE_KEY") or ""


def fetch(table, offset, order):
    # Paging needs a fixed order, or rows can repeat or go missing
    # between pages of a table bigger than one page.
    sort = f"&order={order}" if order else ""
    req = urllib.request.Request(
        f"{URL}/rest/v1/{table}?select=*{sort}&limit={PAGE}&offset={offset}",
        headers={
            "apikey": KEY,
            "Authorization": f"Bearer {KEY}",
            "Accept": "application/json",
            # the server also says how many rows the table has in total
            "Prefer": "count=exact",
        },
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        total = None
        cr = r.headers.get("Content-Range") or ""      # e.g. "0-999/4321"
        if "/" in cr and cr.rsplit("/", 1)[1].isdigit():
            total = int(cr.rsplit("/", 1)[1])
        return json.loads(r.read().decode()), total


def export(table, outdir):
    rows, offset, order, total = [], 0, "id", None
    while True:
        try:
            page, t = fetch(table, offset, order)
        except urllib.error.HTTPError as e:
            if e.code == 400 and order and offset == 0:
                order = None          # table has no "id" column: read unsorted, as before
                continue
            print(f"::error::{table} HTTP {e.code} — not backed up")
            return None
        except Exception as e:
            print(f"::error::{table} failed: {e}")
            return None

        if t is not None:
            total = t
        rows.extend(page)
        # Stop on an empty page or once the count is reached. Not on a short
        # page: if the API's "Max rows" setting were ever lowered below
        # PAGE, every page would be short and the rest silently skipped.
        if not page or (total is not None and len(rows) >= total) or (total is None and len(page) < PAGE):
            break
        offset += len(page)

    if total is not None and len(rows) != total:
        print(f"::error::{table}: got {len(rows)} of {total} rows — not a complete copy")
        return None

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
            f"  If database.dump is in this folder (full copy, made when the\n"
            f"  SUPABASE_DB_URL secret is set): pg_restore it into a new\n"
            f"  project — structure, rules and data in one go.\n"
            f"  Otherwise the rebuild is manual: the *.sql files here are the\n"
            f"  change history (schema.sql, then schema_v3 … in number order —\n"
            f"  some of them add or remove demo animals, so read each first),\n"
            f"  then import each .json.gz into its table. Logins (auth.users)\n"
            f"  are not in the .json.gz files: everyone gets a new password.\n"
        )

    print(f"\nExported {ok}/{len(TABLES)} tables, {total} rows total.")

    # Any table missing makes the run red, so the failure e-mail goes out.
    if failed:
        print(f"::error::{failed} of {len(TABLES)} tables failed")
        sys.exit(1)


if __name__ == "__main__":
    main()
