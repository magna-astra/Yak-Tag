#!/usr/bin/env python3
"""
YAK-TAG NFC tag manager — ACR1552U
===================================
Auto-detects NTAG213 / NTAG215 / NTAG216 and uses the right memory map.

    python nfc_tag.py status                 what state is this tag in?
    python nfc_tag.py diag                   raw config dump (troubleshooting)
    python nfc_tag.py wipe                   erase user memory
    python nfc_tag.py reset                  erase everything + factory settings
                                             (re-use a tag from another system)
    python nfc_tag.py write YT-008000        write the tap URL
    python nfc_tag.py rewrite YT-008000      wipe + write onto a used tag
    python nfc_tag.py setpass                choose YOUR secret tag password (once)
    python nfc_tag.py protect                set write password (REVERSIBLE)
    python nfc_tag.py unprotect              remove the write password
    python nfc_tag.py verify YT-008000
    python nfc_tag.py batch YT-009001 YT-009100   write a whole range, tag after tag
    python nfc_tag.py uidsql                 SQL that records all chip IDs in the dashboard

TAG TYPES — they are NOT interchangeable:
    NTAG213  144 bytes user memory   (CC byte = 0x12)
    NTAG215  504 bytes user memory   (CC byte = 0x3E)
    NTAG216  888 bytes user memory   (CC byte = 0x6D)
    Each has config pages in a different place. This tool reads the
    Capability Container on page 3 and adapts automatically.

USE `protect`, NOT A PERMANENT LOCK:
    Password protection stops a farmer rewriting a tag but lets YOU
    rewrite it. A permanently locked tag can never be rewritten by
    anyone — it becomes waste the moment the animal is sold or the
    data was wrong.

PASSWORD: every YAK-TAG tag is protected with YKTG (owner's decision,
2026-10-11) — no setup needed. YKTG is visible in this public repo, so
someone with a password-capable NFC app could rewrite a tag; to change
it later, `setpass` (tag_password.txt) or YT_TAG_PASSWORD override it.

NO NUMBER TWICE: every write is logged in written_tags.csv next to this
script. A number already written on another chip, or a chip that already
carries a number, is refused. `batch` also checks online that each number
exists in the dashboard and has no animal.
"""

import concurrent.futures
import json
import os
import re
import sys
import time
import urllib.request
from datetime import datetime
from getpass import getpass
from pathlib import Path

try:
    from smartcard.System import readers
    from smartcard.util import toHexString
except ImportError:
    print("Missing dependency. Run:  pip install pyscard")
    sys.exit(1)

# ============================================================
# CONFIG — change before production
# ============================================================
BASE_URL = "https://yaktag.org/t.html?tag="

# The write password (4 characters). YAK-TAG standard: YKTG (owner's
# decision 2026-10-11). YT_TAG_PASSWORD or tag_password.txt (`setpass`,
# git-ignored) override it.
PASSWORD_FILE    = Path(__file__).with_name("tag_password.txt")
DEFAULT_PASSWORD = b"YKTG"

# Every chip written on this PC: tag_code,uid,written_at (git-ignored).
LOG_FILE = Path(__file__).with_name("written_tags.csv")

# Public project address + publishable key (the same as config.js), for
# the read-only "is this number ready in the dashboard?" check.
SUPABASE_URL = "https://mjijgxfmkgtxmpbmshtl.supabase.co"
SUPABASE_KEY = "sb_publishable_npSJ3ZAWO_ODx_cXbvORoQ__t-_1GiJ"
TAG_PACK     = b"\x59\x41"      # 2 bytes

# ============================================================
# Tag profiles, keyed by Capability Container size byte (page 3, byte 2)
# ============================================================
TAG_PROFILES = {
    0x12: {"name": "NTAG213", "user_bytes": 144,
           "first_page": 4, "last_page": 39,
           "dyn_lock": 40, "cfg0": 41, "cfg1": 42, "pwd": 43, "pack": 44},
    0x3E: {"name": "NTAG215", "user_bytes": 504,
           "first_page": 4, "last_page": 129,
           "dyn_lock": 130, "cfg0": 131, "cfg1": 132, "pwd": 133, "pack": 134},
    0x6D: {"name": "NTAG216", "user_bytes": 888,
           "first_page": 4, "last_page": 225,
           "dyn_lock": 226, "cfg0": 227, "cfg1": 228, "pwd": 229, "pack": 230},
}

PAGE_SIZE = 4
STATIC_LOCK_PAGE = 2
CC_PAGE = 3

URI_PREFIXES = {0x01: "http://www.", 0x02: "https://www.",
                0x03: "http://",     0x04: "https://"}


# ---------------- low level ----------------

def get_connection():
    r = readers()
    if not r:
        print("No PC/SC reader found. Is the ACR1552U plugged in?")
        sys.exit(1)
    # The ACR1552U shows two slots: "PICC" (the NFC antenna) and "SAM".
    picc = [x for x in r if "PICC" in str(x)] or r
    conn = picc[0].createConnection()
    try:
        conn.connect()
    except Exception:
        # pyscard raises NoCardException with a long traceback otherwise
        print("No tag on the reader. Put ONE tag flat on the middle of the reader")
        print("(not two at once) and run the command again.")
        sys.exit(1)
    return conn


def get_uid(conn):
    data, sw1, sw2 = conn.transmit([0xFF, 0xCA, 0x00, 0x00, 0x00])
    if (sw1, sw2) != (0x90, 0x00):
        raise RuntimeError(f"Get UID failed: SW={sw1:02X}{sw2:02X}")
    return toHexString(data).replace(" ", "")


def read_pages(conn, start_page, num_pages):
    out = bytearray()
    page, remaining = start_page, num_pages
    while remaining > 0:
        chunk = min(remaining, 4)
        data, sw1, sw2 = conn.transmit([0xFF, 0xB0, 0x00, page, chunk * PAGE_SIZE])
        if (sw1, sw2) != (0x90, 0x00):
            raise RuntimeError(f"Read page {page} failed: SW={sw1:02X}{sw2:02X}")
        out += bytearray(data)
        page += chunk
        remaining -= chunk
    return bytes(out)


def write_page(conn, page, four_bytes):
    data, sw1, sw2 = conn.transmit([0xFF, 0xD6, 0x00, page, 0x04] + list(four_bytes))
    if (sw1, sw2) != (0x90, 0x00):
        raise RuntimeError(f"Write page {page} failed: SW={sw1:02X}{sw2:02X}")


def detect_profile(conn):
    """Reads the Capability Container to work out which NTAG this is."""
    cc = read_pages(conn, CC_PAGE, 1)
    if len(cc) < 4 or cc[0] != 0xE1:
        raise RuntimeError(
            f"Not an NDEF-formatted NFC Forum tag (CC = {' '.join(f'{b:02X}' for b in cc)}). "
            "This tool supports NTAG213/215/216."
        )
    size_byte = cc[2]
    profile = TAG_PROFILES.get(size_byte)
    if not profile:
        raise RuntimeError(
            f"Unknown tag type (CC size byte = 0x{size_byte:02X}). "
            f"Supported: {', '.join(p['name'] for p in TAG_PROFILES.values())}."
        )
    return profile


def load_password():
    raw = os.environ.get("YT_TAG_PASSWORD")
    if raw is None and PASSWORD_FILE.exists():
        raw = PASSWORD_FILE.read_text(encoding="utf-8").strip()
    if raw is None:
        return DEFAULT_PASSWORD
    pw = raw.encode("ascii", errors="replace")
    if len(pw) != 4:
        print(f"Tag password must be exactly 4 characters ({PASSWORD_FILE.name} / YT_TAG_PASSWORD).")
        sys.exit(1)
    return pw


TAG_PASSWORD = load_password()   # YKTG unless overridden


def password_source():
    if os.environ.get("YT_TAG_PASSWORD"):
        return "from YT_TAG_PASSWORD"
    if PASSWORD_FILE.exists():
        return f"from {PASSWORD_FILE.name}"
    return "YKTG (YAK-TAG standard)"


def authenticate(conn, password=None):
    """PWD_AUTH via ACR pseudo-APDU. Returns True on success."""
    password = password or TAG_PASSWORD
    if password is None:
        return False
    apdu = [0xFF, 0x00, 0x00, 0x00, 0x07, 0xD4, 0x42, 0x1B] + list(password)
    try:
        data, sw1, sw2 = conn.transmit(apdu)
        return (sw1, sw2) == (0x90, 0x00) and len(data) >= 2
    except Exception:
        return False


# ---------------- NDEF ----------------

def build_ndef_url(url):
    prefix_code, rest = 0x00, url
    for code, prefix in sorted(URI_PREFIXES.items(), key=lambda kv: -len(kv[1])):
        if url.startswith(prefix):
            prefix_code, rest = code, url[len(prefix):]
            break
    payload = bytes([prefix_code]) + rest.encode("utf-8")
    type_field = b"U"
    record = bytes([0xD1, len(type_field), len(payload)]) + type_field + payload
    if len(record) < 255:
        return bytes([0x03, len(record)]) + record + bytes([0xFE])
    return (bytes([0x03, 0xFF, (len(record) >> 8) & 0xFF, len(record) & 0xFF])
            + record + bytes([0xFE]))


def find_ndef_tlv(raw):
    """Walks the TLV chain to find the NDEF block.

    Tags often begin with a Lock Control TLV (0x01) before the NDEF
    TLV (0x03) — a tag showing '01 03 A0 0C' at page 4 is exactly that.
    Assuming NDEF sits at offset 0 would misread such a tag as corrupt.
    """
    i = 0
    while i < len(raw):
        t = raw[i]
        if t == 0x00:            # NULL TLV, skip
            i += 1
            continue
        if t == 0xFE:            # terminator
            return None
        if i + 1 >= len(raw):
            return None
        length = raw[i + 1]
        if length == 0xFF:       # 3-byte length form
            if i + 3 >= len(raw):
                return None
            length = (raw[i + 2] << 8) | raw[i + 3]
            value_start = i + 4
        else:
            value_start = i + 2
        if t == 0x03:            # NDEF message TLV
            return raw[value_start:value_start + length]
        i = value_start + length
    return None


def ndef_empty(raw):
    """True when the tag holds no NDEF message: all zeros, or only NULL /
    lock-control / memory-control TLVs and an EMPTY NDEF TLV. New NTAG213/
    215 tags come from the factory formatted like that (03 00 FE)."""
    i = 0
    while i < len(raw):
        t = raw[i]
        if t == 0x00:                    # NULL TLV
            i += 1
            continue
        if t == 0xFE:                    # terminator
            return True
        if i + 1 >= len(raw):
            return True
        length, start = raw[i + 1], i + 2
        if length == 0xFF:
            if i + 3 >= len(raw):
                return False
            length, start = (raw[i + 2] << 8) | raw[i + 3], i + 4
        if t == 0x03:                    # NDEF message TLV
            return length == 0
        if t in (0x01, 0x02, 0xFD):      # lock / memory control, proprietary
            i = start + length
            continue
        return False                     # something else: real data
    return True


def parse_ndef_url(raw):
    try:
        rec = find_ndef_tlv(raw)
        if not rec:
            return None
        tl, pl = rec[1], rec[2]
        payload = rec[3 + tl: 3 + tl + pl]
        return URI_PREFIXES.get(payload[0], "") + payload[1:].decode("utf-8", errors="replace")
    except Exception:
        return None


# ---------------- state ----------------

def tag_state(conn):
    uid = get_uid(conn)
    prof = detect_profile(conn)
    state = {"uid": uid, "profile": prof, "url": None,
             "hardware_locked": False, "password_protected": False, "blank": True}

    try:
        static = read_pages(conn, STATIC_LOCK_PAGE, 1)
        if static[2] != 0x00 or static[3] != 0x00:
            state["hardware_locked"] = True
    except Exception:
        pass

    try:
        dyn = read_pages(conn, prof["dyn_lock"], 1)
        if dyn[0] != 0x00 or dyn[1] != 0x00 or dyn[2] != 0x00:
            state["hardware_locked"] = True
    except Exception:
        pass

    try:
        cfg = read_pages(conn, prof["cfg0"], 1)
        if len(cfg) >= 4 and cfg[3] != 0xFF:
            state["password_protected"] = True
    except Exception:
        state["password_protected"] = False

    try:
        pages = prof["last_page"] - prof["first_page"] + 1
        raw = read_pages(conn, prof["first_page"], min(pages, 40))
        state["url"] = parse_ndef_url(raw)
        state["blank"] = ndef_empty(raw)
        state["raw_yak"] = b"yaktag.org" in raw
    except Exception:
        pass

    return state


def print_state(s):
    p = s["profile"]
    print("=" * 60)
    print(f"UID:                 {s['uid']}")
    print(f"Tag type:            {p['name']}  ({p['user_bytes']} bytes user memory)")
    print(f"Current URL:         {s['url'] or '(none)'}")
    print(f"Blank:               {'yes' if s['blank'] else 'no'}")
    print(f"Password protected:  {'YES' if s['password_protected'] else 'no'}")
    print(f"Hardware locked:     {'YES — PERMANENT' if s['hardware_locked'] else 'no'}")
    print("=" * 60)
    if s["hardware_locked"]:
        print("Permanently locked. Cannot be rewritten by anyone, ever.")
        print("Retire it in the database and use a fresh tag.")
    elif s["password_protected"]:
        print("Password protected. YAK-TAG tags use YKTG, which this tool opens itself.")
        print("A tag from another system (e.g. OneTag) needs that system's tool first")
        print("(OneTag: remove-password.js), then  python nfc_tag.py reset.")
    elif not s["blank"]:
        print("Has data but unprotected. `rewrite` will overwrite it.")
    else:
        print("Blank and ready to write.")


# ---------------- commands ----------------

def cmd_diag():
    conn = get_connection()
    print(f"UID: {get_uid(conn)}\n")

    cc = read_pages(conn, CC_PAGE, 1)
    print(f"Capability (pg 3)      {' '.join(f'{b:02X}' for b in cc)}")
    try:
        prof = detect_profile(conn)
    except RuntimeError as e:
        print(f"  -> {e}\n")
        return

    print(f"  -> detected {prof['name']}, {prof['user_bytes']} bytes user memory")
    print(f"  -> user pages {prof['first_page']}-{prof['last_page']}, "
          f"cfg at {prof['cfg0']}/{prof['cfg1']}, pwd at {prof['pwd']}\n")

    for name, page in [("Static lock", STATIC_LOCK_PAGE),
                       ("User start", prof["first_page"]),
                       ("Dyn lock", prof["dyn_lock"]),
                       ("CFG0", prof["cfg0"]),
                       ("CFG1", prof["cfg1"])]:
        try:
            raw = read_pages(conn, page, 1)
            print(f"{name:14} (pg {page:3})  {' '.join(f'{b:02X}' for b in raw)}")
        except Exception as e:
            print(f"{name:14} (pg {page:3})  READ FAILED: {e}")

    raw = read_pages(conn, prof["first_page"], 12)
    print("\nFirst 48 bytes of user memory:")
    for i in range(0, len(raw), 16):
        print("  " + " ".join(f"{b:02X}" for b in raw[i:i + 16]))
    print(f"\nParsed URL: {parse_ndef_url(raw) or '(none found)'}")


def cmd_status():
    conn = get_connection()
    print_state(tag_state(conn))


def wipe_user_memory(conn, prof):
    blank = b"\x00\x00\x00\x00"
    for page in range(prof["first_page"], prof["last_page"] + 1):
        write_page(conn, page, blank)


def cmd_wipe():
    conn = get_connection()
    s = tag_state(conn)
    print_state(s)

    if s["hardware_locked"]:
        print("\nCannot wipe: permanently locked.")
        return
    if s["password_protected"] and not authenticate(conn):
        print("\nCould not authenticate — attempting anyway.")

    if input("\nErase all data on this tag? Type WIPE: ").strip() != "WIPE":
        print("Aborted.")
        return

    wipe_user_memory(conn, s["profile"])
    print("Tag wiped.")


def cmd_write(tag_code, force=False):
    conn = get_connection()
    s = tag_state(conn)
    prof = s["profile"]

    if s["hardware_locked"]:
        print_state(s)
        print("\nCannot write: permanently locked. Use a different tag.")
        return

    if s["password_protected"]:
        if authenticate(conn):
            print("Authenticated with tag password.")
        else:
            print("Could not authenticate — attempting write anyway.")

    if not check_unique(tag_code, s["uid"], moving=force):
        return

    if not s["blank"] and not force:
        print_state(s)
        print("\nThis tag already holds data.")
        print(f"Run:  python nfc_tag.py rewrite {tag_code}")
        return

    url = BASE_URL + tag_code
    tlv = build_ndef_url(url)
    capacity = prof["user_bytes"]
    if len(tlv) > capacity:
        print(f"URL too long: needs {len(tlv)} bytes, {prof['name']} holds {capacity}.")
        print("Shorten BASE_URL (a custom domain helps) or use NTAG215/216.")
        return

    if not s["blank"]:
        print("Erasing old data…")
        wipe_user_memory(conn, prof)

    print(f"Tag type: {prof['name']}")
    print(f"Writing:  {url}")
    print(f"Bytes:    {len(tlv)} of {capacity}")

    blob = tlv + b"\x00" * ((-len(tlv)) % 4)
    page = prof["first_page"]
    for i in range(0, len(blob), 4):
        write_page(conn, page, blob[i:i + 4])
        page += 1

    check = read_pages(conn, prof["first_page"], 20)
    readback = parse_ndef_url(check)
    if readback == url:
        log_written(tag_code, s["uid"])
        print(f"\nVerified OK. UID {s['uid']} now points to {tag_code}.")
        print("\nRecord the chip UID: dashboard -> Тагууд -> row " + tag_code + " -> '+ UID' ->")
        print(f"  {s['uid']}")
        print("(or later, for many tags at once:  python nfc_tag.py uidsql)")
    else:
        print(f"\nMISMATCH — read back: {readback}")
        print("Do NOT put this tag on an animal.")


def cmd_reset():
    """Make a used tag like new: empty memory, no password, no UID/counter
    mirror (other systems, e.g. OneTag, switch the mirror on — it would
    write the chip ID into our address on every read)."""
    conn = get_connection()
    s = tag_state(conn)
    prof = s["profile"]
    print_state(s)

    if s["hardware_locked"]:
        print("\nCannot reset: permanently locked. Retire it, use a new tag.")
        return
    if s["password_protected"] and not authenticate(conn):
        print("\nThis tag is locked with a password this tool does not have:")
        print("- a OneTag tag: run OneTag's remove-password.js first (its tag-writer")
        print("  folder), then run reset again;")
        print("- a tag protected with another password: it cannot be reset; put it aside.")
        return

    print("\nThis erases the address and every setting on the chip.")
    if input("Make this tag like new? Type RESET: ").strip() != "RESET":
        print("Aborted — nothing changed.")
        return

    print("Erasing memory…")
    wipe_user_memory(conn, prof)
    try:
        # factory settings: no mirror, protection off; then default password
        write_page(conn, prof["cfg0"], bytes([0x04, 0x00, 0x00, 0xFF]))
        cfg1 = bytearray(read_pages(conn, prof["cfg1"], 1))
        cfg1[0] = 0x00                  # PROT off, config not locked, no auth limit, no NFC counter
        write_page(conn, prof["cfg1"], bytes(cfg1))
        write_page(conn, prof["pwd"], b"\xff\xff\xff\xff")
        write_page(conn, prof["pack"], b"\x00\x00\x00\x00")
    except RuntimeError as e:
        print(f"\nMemory erased, but the settings could not be reset ({e}).")
        print("The previous system may have locked its settings for good. Do NOT")
        print("use this tag on an animal; put it aside.")
        return

    cfg0 = read_pages(conn, prof["cfg0"], 1)
    after = tag_state(conn)
    if after["blank"] and not after["password_protected"] and (cfg0[0] & 0xC0) == 0:
        print(f"\nDone. Tag {after['uid']} is like new: empty, no password, no mirror.")
        print("Next: give it a number —  python nfc_tag.py write YT-008005  — then protect.")
    else:
        print("\nReset finished but the check failed — run  python nfc_tag.py diag  and ask for help.")


def cmd_rewrite(tag_code):
    conn = get_connection()
    s = tag_state(conn)
    print_state(s)

    if s["hardware_locked"]:
        print("\nCannot rewrite: permanently locked. Retire it, use a new tag.")
        return

    if s["url"]:
        print(f"\nCurrently points to:\n  {s['url']}")
        print("Rewriting erases that permanently.")
        print("\nMake sure the old animal is closed out in the database")
        print("(status sold/dead/lost) first, or the tag and the record")
        print("will point at different animals.")

    if input(f"\nErase and rewrite as {tag_code}? Type REWRITE: ").strip() != "REWRITE":
        print("Aborted — nothing changed.")
        return

    cmd_write(tag_code, force=True)


def apply_protection(conn, prof):
    write_page(conn, prof["pwd"], TAG_PASSWORD)
    write_page(conn, prof["pack"], TAG_PACK + b"\x00\x00")

    # CFG1 before CFG0: once AUTH0 is set, every page from the first user
    # page on (CFG1 included) refuses writes without the password.
    cfg1 = bytearray(read_pages(conn, prof["cfg1"], 1))
    cfg1[0] = cfg1[0] & 0x7F            # PROT=0: write-protect only, stays readable
    write_page(conn, prof["cfg1"], bytes(cfg1))

    cfg0 = bytearray(read_pages(conn, prof["cfg0"], 1))
    cfg0[3] = prof["first_page"]        # protect from first user page onward (last step)
    write_page(conn, prof["cfg0"], bytes(cfg0))


def cmd_protect():
    conn = get_connection()
    s = tag_state(conn)
    prof = s["profile"]

    if s["hardware_locked"]:
        print("Permanently locked; protection is irrelevant.")
        return
    if s["password_protected"]:
        print("Already password protected.")
        return

    print(f"Tag type: {prof['name']}")
    print("Setting write password. REVERSIBLE via `unprotect`.\n")
    print(f"Password: {password_source()}")
    if input("Proceed? Type PROTECT: ").strip() != "PROTECT":
        print("Aborted.")
        return

    apply_protection(conn, prof)
    print("Protected. Still readable by any phone; writes need the password.")


def cmd_unprotect():
    conn = get_connection()
    s = tag_state(conn)
    prof = s["profile"]

    if s["hardware_locked"]:
        print("Permanently locked — cannot be changed.")
        return
    if not s["password_protected"]:
        print("Not password protected.")
        return
    if not authenticate(conn):
        print("Password rejected. Cannot unprotect.")
        return

    cfg0 = bytearray(read_pages(conn, prof["cfg0"], 1))
    cfg0[3] = 0xFF
    write_page(conn, prof["cfg0"], bytes(cfg0))
    print("Protection removed.")


def cmd_setpass():
    print("Choose the secret password that protects your tags from rewriting.")
    print("Not needed for YAK-TAG: the standard password is YKTG. Only use this to")
    print("change it for every tag from now on. Exactly 4 letters/digits.\n")
    if PASSWORD_FILE.exists():
        print(f"{PASSWORD_FILE.name} already exists. Tags protected with the OLD")
        print("password need the old one to be rewritten — keep a copy of it.\n")
        if input("Replace it? Type REPLACE: ").strip() != "REPLACE":
            print("Aborted — nothing changed.")
            return
    pw = getpass("New tag password (hidden): ").strip()
    if pw != getpass("Again: ").strip():
        print("The two entries differ. Nothing saved.")
        return
    if len(pw) != 4 or not pw.isascii() or not pw.isalnum():
        print("Must be exactly 4 letters/digits. Nothing saved.")
        return
    PASSWORD_FILE.write_text(pw, encoding="utf-8")
    print(f"Saved in {PASSWORD_FILE}")
    print("Write it down and keep it somewhere safe (not on GitHub, not in chat).")
    print("Every computer that writes your tags needs this same file.")


def cmd_verify(tag_code):
    conn = get_connection()
    s = tag_state(conn)
    expected = BASE_URL + tag_code
    print(f"UID:      {s['uid']}")
    print(f"Tag type: {s['profile']['name']}")
    print(f"Expected: {expected}")
    print(f"Found:    {s['url']}")
    print("RESULT: MATCH" if s["url"] == expected else "RESULT: MISMATCH")



# ---------------- no number twice ----------------

def load_log():
    """{code: uid}, {uid: code} from written_tags.csv (later lines win)."""
    by_code, by_uid = {}, {}
    if LOG_FILE.exists():
        for line in LOG_FILE.read_text(encoding="utf-8").splitlines()[1:]:
            parts = line.strip().split(",")
            if len(parts) >= 2 and parts[0] and parts[1]:
                by_code[parts[0]] = parts[1]
                by_uid[parts[1]] = parts[0]
    return by_code, by_uid


def log_written(code, uid):
    new = not LOG_FILE.exists()
    with LOG_FILE.open("a", encoding="utf-8") as f:
        if new:
            f.write("tag_code,uid,written_at\n")
        f.write(f"{code},{uid},{datetime.now().isoformat(timespec='seconds')}\n")


def check_unique(code, uid, moving=False):
    by_code, by_uid = load_log()
    if code in by_code and by_code[code] != uid:
        print(f"\n{code} was already written on another chip ({by_code[code]}).")
        print("Every number goes on ONE chip only — use the next free number.")
        return False
    if uid in by_uid and by_uid[uid] != code and not moving:
        print(f"\nThis chip already carries {by_uid[uid]}. Use a new chip, or on purpose:")
        print(f"  python nfc_tag.py rewrite {code}   (then clear {by_uid[uid]}'s UID in the dashboard)")
        return False
    return True


def tag_states_online(codes):
    """public_tag_state for each code: 'new' = in the dashboard, farm active,
    no animal. Read-only; returns {code: 'new' | None | 'error'}."""
    def one(code):
        req = urllib.request.Request(
            f"{SUPABASE_URL}/rest/v1/rpc/public_tag_state",
            data=json.dumps({"p_tag_code": code}).encode(),
            headers={"apikey": SUPABASE_KEY, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                return code, json.loads(r.read().decode() or "null")
        except Exception:
            return code, "error"
    with concurrent.futures.ThreadPoolExecutor(6) as ex:
        return dict(ex.map(one, codes))


def uid_sql(pairs, title):
    rows = ",\n".join(f"  ('{c}', '{u}')" for c, u in pairs)
    return f"""-- YAK-TAG: chip IDs written with nfc_tag.py — {title}
-- Supabase -> SQL Editor -> paste all -> Run. Safe to run twice.
-- The result lists every number; saved = true means the dashboard has its chip ID.
with v(tag_code, uid) as (values
{rows}
), upd as (
  update public.tags t
     set nfc_uid    = v.uid,
         written_at = coalesce(t.written_at, now()),
         status     = case when t.status = 'blank' then 'written' else t.status end
    from v
   where t.tag_code = v.tag_code
     and t.nfc_uid is null
     and not exists (select 1 from public.tags o where o.nfc_uid = v.uid)
  returning t.id, t.farm_id, t.tag_code, t.nfc_uid
), hist as (
  insert into public.audit_log (farm_id, actor_id, action, entity, entity_id, detail)
  select farm_id, null, 'tag_uid', 'tags', id,
         jsonb_build_object('tag_code', tag_code, 'nfc_uid', nfc_uid, 'source', 'nfc_tag.py')
    from upd
  returning 1
)
select v.tag_code as tag, v.uid as chip_uid,
       coalesce(u.tag_code is not null or t.nfc_uid = v.uid, false) as saved,
       case when t.id is null then 'number not in the dashboard'
            when u.tag_code is not null then 'saved now'
            when t.nfc_uid = v.uid then 'already saved'
            else 'row has another UID: ' || t.nfc_uid end as note
  from v
  left join public.tags t on t.tag_code = v.tag_code
  left join upd u on u.tag_code = v.tag_code
 order by 1;
"""


def save_uid_sql(pairs, title):
    out = Path(__file__).with_name(f"uid_import_{datetime.now():%Y-%m-%d_%H%M}.sql")
    out.write_text(uid_sql(pairs, title), encoding="utf-8")
    return out


def cmd_uidsql():
    by_code, _ = load_log()
    if not by_code:
        print("No tags written on this PC yet (written_tags.csv is empty).")
        return
    out = save_uid_sql(sorted(by_code.items()), f"all {len(by_code)} tags written on this PC")
    print(f"Saved {out.name} ({len(by_code)} tags).")
    print("Open it, copy everything into Supabase -> SQL Editor -> Run.")


# ---------------- batch: a whole range, tag after tag ----------------

def try_connect():
    try:
        r = readers()
    except Exception:
        return None
    if not r:
        return None
    picc = [x for x in r if "PICC" in str(x)] or r
    conn = picc[0].createConnection()
    try:
        conn.connect()
        return conn
    except Exception:
        return None


def close(conn):
    try:
        conn.disconnect()
    except Exception:
        pass


def wait_for_tag():
    while True:
        conn = try_connect()
        if conn is not None:
            return conn
        time.sleep(0.3)


def wait_for_removal(uid, empty_needed=4):
    """Until the reader has been EMPTY for ~1 s (the ACR1552U reports
    'removed' for a split second while a tag still lies on it), or a
    different chip is on it."""
    empty = 0
    while empty < empty_needed:
        conn = try_connect()
        if conn is None:
            empty += 1
        else:
            same = True
            if uid is not None:
                try:
                    same = get_uid(conn) == uid
                except Exception:
                    same = True
            close(conn)
            if not same:
                return
            empty = 0
        time.sleep(0.3)


def code_range(first, last):
    m1 = re.fullmatch(r"([A-Z]{1,6})-(\d{6})", first)
    m2 = re.fullmatch(r"([A-Z]{1,6})-(\d{6})", last)
    if not (m1 and m2) or m1.group(1) != m2.group(1) or int(m1.group(2)) > int(m2.group(2)):
        return None
    return [f"{m1.group(1)}-{n:06d}" for n in range(int(m1.group(2)), int(m2.group(2)) + 1)]


def cmd_batch(first, last):
    codes = code_range(first, last)
    if not codes:
        print("Give the first and last number of ONE range, e.g.  batch YT-009001 YT-009100")
        return
    if len(codes) > 1000:
        print("At most 1000 numbers per batch.")
        return
    if not readers():
        print("No PC/SC reader found. Is the ACR1552U plugged in?")
        return

    by_code, by_uid = load_log()
    done_before = [c for c in codes if c in by_code]
    todo = [c for c in codes if c not in by_code]
    print(f"Range {codes[0]} … {codes[-1]}: {len(codes)} numbers, {len(done_before)} already written on this PC.")
    if not todo:
        print("Nothing left to write in this range.")
        return

    print("Checking the numbers in the dashboard (read-only)…")
    states = tag_states_online(todo)
    if all(v == "error" for v in states.values()):
        print("No internet: the numbers cannot be checked against the dashboard.")
        if input("Write anyway (only numbers you created in the dashboard!)? Type YES: ").strip() != "YES":
            print("Stopped — nothing written.")
            return
        ready = todo
    else:
        ready = [c for c in todo if states.get(c) == "new"]
        missing = [c for c in todo if states.get(c) != "new"]
        if missing:
            print(f"{len(missing)} numbers are NOT ready (not created, no farm, farm paused, or already")
            print(f"on an animal) and will be skipped: {', '.join(missing[:8])}{' …' if len(missing) > 8 else ''}")
        if not ready:
            print("No number of this range is ready. Create them first: dashboard -> Тагууд -> + Таг үүсгэх.")
            return

    print(f"\n{len(ready)} numbers to write: {ready[0]} … {ready[-1]}")
    print(f"Every tag is written, checked and protected (password {password_source()}).")
    print("Put ONE new tag on the reader at a time. Ctrl+C stops at any moment.\n")

    written = []
    unfinished = set()        # chips that moved away while we wrote them (this session)
    told = set()              # (uid, code) skip messages already shown
    in_range = set(codes)
    i, asked = 0, None
    try:
        while i < len(ready):
            code = ready[i]
            if asked != code:
                print(f"[{i + 1}/{len(ready)}] Put a new tag on the reader for {code} …")
                asked = code
            conn = wait_for_tag()
            status, uid, msg = batch_one(conn, code, by_code, by_uid, unfinished, in_range)
            close(conn)
            if status == "ok":
                log_written(code, uid)
                by_code[code], by_uid[uid] = uid, code
                unfinished.discard(uid)
                written.append((code, uid))
                print(f"   OK {code}  chip {uid}  written, checked, protected. Remove the tag.")
                i += 1
            elif status == "moved" or (uid, code) not in told:
                told.add((uid, code))
                print(f"   x {msg}")
            wait_for_removal(uid)
    except KeyboardInterrupt:
        print("\nStopped by Ctrl+C.")
    except Exception as e:                       # never lose what was already written
        print(f"\nStopped: {e}")
    finally:
        print(f"\nDone: {len(written)} tags written in this batch.")
        if written:
            print(f"First {written[0][0]}, last {written[-1][0]}. Label the box with that range.")
            out = save_uid_sql(written, f"batch {written[0][0]} … {written[-1][0]} ({len(written)} tags)")
            print(f"\nChip IDs for the dashboard: {out.name}")
            print("Open it, copy everything into Supabase -> SQL Editor -> Run (once).")
        if unfinished:
            print(f"\n{len(unfinished)} chip(s) moved away while being written and were not finished.")
            print("They are NOT usable as they are: run  python nfc_tag.py reset  on each, then reuse.")


def batch_one(conn, code, by_code, by_uid, unfinished, in_range):
    """One chip for one number. Returns (status, uid, message)."""
    try:
        s = tag_state(conn)
    except Exception:
        return "retry", None, "Could not read the tag — lay it flat in the middle of the reader."
    uid, prof = s["uid"], s["profile"]
    keep = f"{code} stays free."
    if uid in by_uid:
        return "skip", uid, f"Skipped: this chip already carries {by_uid[uid]}. Put it aside; {keep}"
    if s["hardware_locked"]:
        return "skip", uid, f"Skipped: this chip is permanently locked. Put it aside; {keep}"

    # our own unfinished write: this session, or an unprotected chip with a
    # broken / not-yet-logged YAK-TAG address of this range
    own = uid in unfinished
    if not own and not s["password_protected"]:
        if s["url"] and "yaktag.org/t.html?tag=" in s["url"]:
            c = s["url"].rsplit("=", 1)[-1]
            own = c in in_range and c not in by_code
        elif s.get("raw_yak"):
            own = True
    if not own:
        if s["url"] and "yaktag.org/t.html?tag=" in s["url"]:
            return "skip", uid, f"Skipped: this chip is already a YAK-TAG tag ({s['url'].rsplit('=', 1)[-1]}). Put it aside; {keep}"
        if not s["blank"]:
            what = s["url"] or "unknown data"
            return "skip", uid, (f"Skipped: this chip holds other data ({what[:60]}). "
                                 f"Put it aside and later run  python nfc_tag.py reset  on it; {keep}")
    if s["password_protected"] and not authenticate(conn):
        return "skip", uid, f"Skipped: this chip is locked with another password. Put it aside; {keep}"

    url = BASE_URL + code
    tlv = build_ndef_url(url)
    if len(tlv) > prof["user_bytes"]:
        return "skip", uid, f"Skipped: {prof['name']} is too small. Put it aside; {keep}"
    try:
        blob = tlv + b"\x00" * ((-len(tlv)) % 4)
        if own:                                  # clear the rest of a half-written address
            blob += b"\x00" * 16
        page = prof["first_page"]
        for k in range(0, len(blob), 4):
            write_page(conn, page, blob[k:k + 4])
            page += 1
        if parse_ndef_url(read_pages(conn, prof["first_page"], 20)) != url:
            raise RuntimeError("read-back does not match")
        if read_pages(conn, prof["cfg0"], 1)[3] == 0xFF:
            apply_protection(conn, prof)
        if read_pages(conn, prof["cfg0"], 1)[3] != prof["first_page"]:
            raise RuntimeError("protection did not stick")
    except Exception:
        unfinished.add(uid)
        return "moved", uid, (f"The tag moved while writing. Put the SAME tag back, flat and still — "
                              f"it will be finished as {code}.")
    return "ok", uid, ""

def main():
    if len(sys.argv) < 2:
        print(__doc__); return
    cmd = sys.argv[1]
    if cmd in ("write", "rewrite", "verify") and len(sys.argv) == 3:
        # Same shape the dashboard makes (YT-008000): a typo such as
        # "yt-8000" must not end up on a tag nobody can look up.
        sys.argv[2] = sys.argv[2].strip().upper()
        if not re.fullmatch(r"[A-Z]{1,6}-\d{6}", sys.argv[2]):
            print(f"Tag code '{sys.argv[2]}' is not valid. Use the code from the dashboard, e.g. YT-008000.")
            return
    try:
        if cmd == "status": cmd_status()
        elif cmd == "diag": cmd_diag()
        elif cmd == "wipe": cmd_wipe()
        elif cmd == "reset": cmd_reset()
        elif cmd == "write" and len(sys.argv) == 3: cmd_write(sys.argv[2])
        elif cmd == "rewrite" and len(sys.argv) == 3: cmd_rewrite(sys.argv[2])
        elif cmd == "setpass": cmd_setpass()
        elif cmd == "protect": cmd_protect()
        elif cmd == "unprotect": cmd_unprotect()
        elif cmd == "verify" and len(sys.argv) == 3: cmd_verify(sys.argv[2])
        elif cmd == "batch" and len(sys.argv) == 4:
            cmd_batch(sys.argv[2].strip().upper(), sys.argv[3].strip().upper())
        elif cmd == "uidsql": cmd_uidsql()
        else: print(__doc__)
    except RuntimeError as e:
        print(f"Error: {e}")


if __name__ == "__main__":
    main()
