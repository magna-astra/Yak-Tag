#!/usr/bin/env python3
"""
YAK-TAG — copy every animal photo out of Supabase Storage.

Both buckets (cattle-photos = private, cattle-public = the photo strangers
see) are mirrored into OUTDIR/<bucket>/<same path as in Supabase>. Only
photos that are new or changed are downloaded; a photo deleted in Supabase
is removed from the folder too — the backup repo's git history still has
it. Photos never change once saved (they are locked), so the monthly run
is quick after the first one.

Restore: upload each file back to the same bucket under the same path
(Supabase → Storage → bucket → Upload, or the Storage API). The database
rows (cattle_photos.path) already point at these paths.

Env: SUPABASE_URL, SUPABASE_SERVICE_KEY
Usage: python3 scripts/backup_photos.py store/photos
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

BUCKETS = ["cattle-photos", "cattle-public"]
PAGE = 1000

URL = (os.environ.get("SUPABASE_URL") or "").rstrip("/")
KEY = os.environ.get("SUPABASE_SERVICE_KEY") or ""
HEADERS = {"apikey": KEY, "Authorization": f"Bearer {KEY}"}


def list_folder(bucket, prefix):
    """Every entry directly inside one folder (paged)."""
    out, offset = [], 0
    while True:
        body = json.dumps({"prefix": prefix, "limit": PAGE, "offset": offset,
                           "sortBy": {"column": "name", "order": "asc"}}).encode()
        req = urllib.request.Request(f"{URL}/storage/v1/object/list/{bucket}", data=body, method="POST",
                                     headers={**HEADERS, "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            page = json.loads(r.read().decode())
        out.extend(page)
        if len(page) < PAGE:
            return out
        offset += len(page)


def list_files(bucket, prefix=""):
    """{path: size} of every file in the bucket, all folders deep."""
    files = {}
    for e in list_folder(bucket, prefix):
        name = e.get("name") or ""
        if not name or name == ".emptyFolderPlaceholder":
            continue
        path = f"{prefix}/{name}" if prefix else name
        if e.get("id") is None:                      # a folder
            files.update(list_files(bucket, path))
        else:
            files[path] = int((e.get("metadata") or {}).get("size") or -1)
    return files


def download(bucket, path, dest):
    quoted = "/".join(urllib.parse.quote(p, safe="") for p in path.split("/"))
    req = urllib.request.Request(f"{URL}/storage/v1/object/{bucket}/{quoted}", headers=HEADERS)
    with urllib.request.urlopen(req, timeout=120) as r:
        data = r.read()
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = dest + ".part"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, dest)
    return len(data)


def safe_local(root, path):
    """Local file for a storage path; refuses anything that leaves root."""
    dest = os.path.normpath(os.path.join(root, *path.split("/")))
    if not dest.startswith(os.path.normpath(root) + os.sep):
        raise ValueError(f"unsafe path {path!r}")
    return dest


def mirror(bucket, outdir):
    root = os.path.join(outdir, bucket)
    os.makedirs(root, exist_ok=True)
    try:
        remote = list_files(bucket)
    except Exception as e:
        print(f"::error::{bucket}: could not list the photos ({e}) — nothing changed in this folder")
        return None

    new = same = failed = 0
    size = 0
    keep = set()
    for path, rsize in sorted(remote.items()):
        try:
            dest = safe_local(root, path)
        except ValueError as e:
            print(f"::warning::{bucket}: {e} — skipped")
            failed += 1
            continue
        keep.add(dest)
        if os.path.exists(dest) and (rsize < 0 or os.path.getsize(dest) == rsize):
            same += 1
            size += os.path.getsize(dest)
            continue
        try:
            size += download(bucket, path, dest)
            new += 1
        except Exception as e:
            print(f"::warning::{bucket}/{path}: download failed ({e})")
            failed += 1

    # gone from Supabase → gone from the folder (git history keeps it)
    removed = 0
    for d, _, names in os.walk(root):
        for n in names:
            f = os.path.normpath(os.path.join(d, n))
            if f not in keep:
                os.remove(f)
                removed += 1

    print(f"  {bucket}: {len(remote)} photos ({size / 1048576:.1f} MB) — "
          f"{new} new, {same} unchanged, {removed} removed, {failed} failed")
    return failed


def main():
    if not URL or not KEY:
        print("::error::SUPABASE_URL or SUPABASE_SERVICE_KEY not set")
        sys.exit(1)
    outdir = sys.argv[1] if len(sys.argv) > 1 else "photos"
    os.makedirs(outdir, exist_ok=True)

    problems = 0
    for b in BUCKETS:
        r = mirror(b, outdir)
        problems += 1 if r is None else r

    with open(os.path.join(outdir, "README.txt"), "w", encoding="utf-8") as f:
        f.write(
            "YAK-TAG animal photos (monthly copy)\n"
            "cattle-photos = all photos (private), cattle-public = the photo shown\n"
            "to strangers who tap a tag. Same paths as in Supabase Storage.\n\n"
            "Restore: upload each file back to the same bucket under the same path.\n"
            "Deleted photos: in this repo's git history (git log -- photos/).\n"
        )

    # anything not copied makes the run red, so the failure e-mail goes out
    if problems:
        print(f"::error::{problems} problem(s) — see the warnings above")
        sys.exit(1)


if __name__ == "__main__":
    main()
