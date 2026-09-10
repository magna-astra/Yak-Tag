#!/usr/bin/env python3
"""
YAK-TAG NFC tag manager — ACR1552U + NTAG215
=============================================
Full tag lifecycle: inspect, wipe, rewrite, protect, recycle.

    python nfc_tag.py status                 what state is this tag in?
    python nfc_tag.py wipe                   erase user memory (needs password if set)
    python nfc_tag.py write YT-008000        write the tap URL (wipes first)
    python nfc_tag.py rewrite YT-008123      wipe + write a NEW code onto a used tag
    python nfc_tag.py protect                set the write password (reversible)
    python nfc_tag.py unprotect              remove the write password
    python nfc_tag.py verify YT-008000

IMPORTANT — READ THIS BEFORE PRODUCTION:
    Use `protect`, NOT the permanent hardware lock.

    Password protection stops a farmer rewriting a tag, but lets YOU
    rewrite it because you hold the password. A permanently locked
    tag can NEVER be rewritten by anyone, including you — that tag
    becomes waste the moment the cow dies, is sold, or the data was
    wrong. There is no undo.

    The permanent lock lives in nfc_write.py. Avoid it unless you
    have a specific reason.

CHANGE THE PASSWORD BELOW before writing real tags.
Store it somewhere safe. If you lose it, every protected tag becomes
unrewritable — the same dead end as a hardware lock.
"""

import sys

try:
    from smartcard.System import readers
    from smartcard.util import toHexString
except ImportError:
    print("Missing dependency. Run:  pip install pyscard")
    sys.exit(1)

# ============================================================
# CONFIG — change these before writing production tags
# ============================================================
BASE_URL = "https://magna-astra.github.io/Yak-Tag/cow.html?tag="

TAG_PASSWORD = b"YKTG"          # exactly 4 bytes
TAG_PACK     = b"\x59\x41"      # 2-byte acknowledgement ("YA")

# ============================================================
# NTAG215 memory map
# ============================================================
PAGE_SIZE = 4
FIRST_USER_PAGE = 4
LAST_USER_PAGE = 129
CFG_PAGE_0 = 131      # MIRROR / AUTH0
CFG_PAGE_1 = 132      # ACCESS / PROT
PWD_PAGE   = 133      # 4-byte password
PACK_PAGE  = 134      # 2-byte PACK
STATIC_LOCK_PAGE = 2
DYNAMIC_LOCK_PAGE = 130

URI_PREFIXES = {0x01:"http://www.", 0x02:"https://www.", 0x03:"http://", 0x04:"https://"}


# ---------------- low level ----------------

def get_connection():
    r = readers()
    if not r:
        print("No PC/SC reader found. Is the ACR1552U plugged in?")
        sys.exit(1)
    conn = r[0].createConnection()
    conn.connect()
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


def authenticate(conn, password=TAG_PASSWORD):
    """PWD_AUTH (0x1B). Returns True if the tag accepted the password.
    Harmless to call on an unprotected tag — it just fails."""
    apdu = [0xFF, 0x00, 0x00, 0x00, 0x07, 0xD4, 0x42, 0x1B] + list(password)
    try:
        data, sw1, sw2 = conn.transmit(apdu)
        # a successful PWD_AUTH returns the 2-byte PACK
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
    return bytes([0x03, 0xFF, (len(record) >> 8) & 0xFF, len(record) & 0xFF]) + record + bytes([0xFE])


def parse_ndef_url(raw):
    try:
        if raw[0] != 0x03:
            return None
        if raw[1] == 0xFF:
            rec = raw[4:4 + ((raw[2] << 8) | raw[3])]
        else:
            rec = raw[2:2 + raw[1]]
        tl, pl = rec[1], rec[2]
        payload = rec[3 + tl: 3 + tl + pl]
        return URI_PREFIXES.get(payload[0], "") + payload[1:].decode("utf-8", errors="replace")
    except Exception:
        return None


# ---------------- state detection ----------------

def tag_state(conn):
    """Works out what condition this tag is in."""
    uid = get_uid(conn)
    state = {"uid": uid, "url": None, "hardware_locked": False,
             "password_protected": False, "blank": True}

    # is it permanently locked? check static + dynamic lock bytes
    try:
        static = read_pages(conn, STATIC_LOCK_PAGE, 1)
        dyn = read_pages(conn, DYNAMIC_LOCK_PAGE, 1)
        if static[2] != 0x00 or static[3] != 0x00 or dyn[0] != 0x00 or dyn[1] != 0x00:
            state["hardware_locked"] = True
    except Exception:
        pass

    # AUTH0 < 0xFF means password protection starts at that page
    try:
        cfg = read_pages(conn, CFG_PAGE_0, 1)
        if cfg[3] != 0xFF:
            state["password_protected"] = True
    except Exception:
        # config pages unreadable usually means read-protected
        state["password_protected"] = True

    try:
        raw = read_pages(conn, FIRST_USER_PAGE, 40)
        state["url"] = parse_ndef_url(raw)
        state["blank"] = all(b == 0x00 for b in raw[:16])
    except Exception:
        pass

    return state


def print_state(s):
    print("=" * 58)
    print(f"UID:                 {s['uid']}")
    print(f"Current URL:         {s['url'] or '(none)'}")
    print(f"Blank:               {'yes' if s['blank'] else 'no'}")
    print(f"Password protected:  {'YES' if s['password_protected'] else 'no'}")
    print(f"Hardware locked:     {'YES — PERMANENT' if s['hardware_locked'] else 'no'}")
    print("=" * 58)
    if s["hardware_locked"]:
        print("This tag is permanently locked. It CANNOT be rewritten by")
        print("anyone, including you. Retire it in the database and use a")
        print("fresh tag. Mark the old one status='retired'.")
    elif s["password_protected"]:
        print("Protected but rewritable — this tool will authenticate")
        print("automatically using the password in TAG_PASSWORD.")
    elif not s["blank"]:
        print("Has data but is unprotected. `rewrite` will overwrite it.")
    else:
        print("Blank and ready to write.")


# ---------------- commands ----------------

def cmd_status():
    conn = get_connection()
    print_state(tag_state(conn))


def wipe_user_memory(conn):
    """Zeroes user memory. Authenticates first if needed."""
    blank = b"\x00\x00\x00\x00"
    for page in range(FIRST_USER_PAGE, LAST_USER_PAGE + 1):
        write_page(conn, page, blank)


def cmd_wipe():
    conn = get_connection()
    s = tag_state(conn)
    print_state(s)

    if s["hardware_locked"]:
        print("\nCannot wipe: this tag is permanently locked. Nothing to do.")
        return

    if s["password_protected"]:
        print("\nAuthenticating…")
        if not authenticate(conn):
            print("Password rejected. Is TAG_PASSWORD correct for this tag?")
            return
        print("Authenticated.")

    if input("\nErase all data on this tag? Type WIPE: ").strip() != "WIPE":
        print("Aborted.")
        return

    wipe_user_memory(conn)
    print("Tag wiped. Ready to be written with a new code.")


def cmd_write(tag_code, force=False):
    conn = get_connection()
    s = tag_state(conn)

    if s["hardware_locked"]:
        print_state(s)
        print("\nCannot write: permanently locked. Use a different tag.")
        return

    if s["password_protected"]:
        if not authenticate(conn):
            print("Password rejected — cannot write to this tag.")
            return

    if not s["blank"] and not force:
        print_state(s)
        print(f"\nThis tag already holds data.")
        print(f"Run:  python nfc_tag.py rewrite {tag_code}")
        print("…to erase it and write the new code.")
        return

    url = BASE_URL + tag_code
    tlv = build_ndef_url(url)
    capacity = (LAST_USER_PAGE - FIRST_USER_PAGE + 1) * PAGE_SIZE
    if len(tlv) > capacity:
        print(f"URL too long: {len(tlv)} bytes, capacity {capacity}.")
        return

    if not s["blank"]:
        print("Erasing old data…")
        wipe_user_memory(conn)

    print(f"Writing: {url}")
    blob = tlv + b"\x00" * ((-len(tlv)) % 4)
    page = FIRST_USER_PAGE
    for i in range(0, len(blob), 4):
        write_page(conn, page, blob[i:i + 4])
        page += 1

    readback = parse_ndef_url(read_pages(conn, FIRST_USER_PAGE, 40))
    if readback == url:
        print(f"Verified OK. UID {s['uid']} now points to {tag_code}.")
        print("\nRemember to record this in the database:")
        print(f"  update tags set nfc_uid='{s['uid']}', status='written',")
        print(f"    written_at=now() where tag_code='{tag_code}';")
    else:
        print(f"MISMATCH — read back: {readback}")
        print("Do NOT put this tag on an animal.")


def cmd_rewrite(tag_code):
    """Recycle a used tag: confirm, wipe, write new code."""
    conn = get_connection()
    s = tag_state(conn)
    print_state(s)

    if s["hardware_locked"]:
        print("\nCannot rewrite: permanently locked. Retire it and use a new tag.")
        return

    if s["url"]:
        print(f"\nThis tag currently points to:\n  {s['url']}")
        print("Rewriting will erase that permanently.")
        print("\nBefore you do this, make sure the old animal is closed out")
        print("in the database (status sold/dead/lost), or you will have a")
        print("tag pointing at one cow and a record pointing at another.")

    if input(f"\nErase and rewrite as {tag_code}? Type REWRITE: ").strip() != "REWRITE":
        print("Aborted — nothing changed.")
        return

    cmd_write(tag_code, force=True)


def cmd_protect():
    conn = get_connection()
    s = tag_state(conn)

    if s["hardware_locked"]:
        print("Tag is permanently locked; password protection is irrelevant.")
        return

    if s["password_protected"]:
        print("Tag is already password protected.")
        return

    print("Setting write password. This is REVERSIBLE — you can remove it")
    print("later with `unprotect`, as long as you know the password.\n")
    print(f"Password in this script: {TAG_PASSWORD.decode()}")
    if input("Proceed? Type PROTECT: ").strip() != "PROTECT":
        print("Aborted.")
        return

    # write password and PACK
    write_page(conn, PWD_PAGE, TAG_PASSWORD)
    write_page(conn, PACK_PAGE, TAG_PACK + b"\x00\x00")

    # AUTH0 = first page requiring auth. 0x04 protects all user memory.
    cfg0 = bytearray(read_pages(conn, CFG_PAGE_0, 1))
    cfg0[3] = 0x04
    write_page(conn, CFG_PAGE_0, bytes(cfg0))

    # PROT bit 7 of ACCESS: 0 = write-protected only (still publicly readable)
    # Keep it readable so any phone can still tap and open the cow page.
    cfg1 = bytearray(read_pages(conn, CFG_PAGE_1, 1))
    cfg1[0] = cfg1[0] & 0x7F
    write_page(conn, CFG_PAGE_1, bytes(cfg1))

    print("Protected. The tag is still readable by any phone, but writes")
    print("now require the password. Keep TAG_PASSWORD safe.")


def cmd_unprotect():
    conn = get_connection()
    s = tag_state(conn)

    if s["hardware_locked"]:
        print("Tag is permanently locked — cannot be changed.")
        return
    if not s["password_protected"]:
        print("Tag is not password protected.")
        return

    if not authenticate(conn):
        print("Password rejected. Cannot unprotect.")
        return

    cfg0 = bytearray(read_pages(conn, CFG_PAGE_0, 1))
    cfg0[3] = 0xFF          # AUTH0 = 0xFF disables protection
    write_page(conn, CFG_PAGE_0, bytes(cfg0))
    print("Protection removed. Tag is freely writable again.")


def cmd_verify(tag_code):
    conn = get_connection()
    expected = BASE_URL + tag_code
    found = parse_ndef_url(read_pages(conn, FIRST_USER_PAGE, 40))
    print(f"UID:      {get_uid(conn)}")
    print(f"Expected: {expected}")
    print(f"Found:    {found}")
    print("RESULT: MATCH" if found == expected else "RESULT: MISMATCH")


def main():
    if len(sys.argv) < 2:
        print(__doc__); return
    cmd = sys.argv[1]
    if cmd == "status": cmd_status()
    elif cmd == "wipe": cmd_wipe()
    elif cmd == "write" and len(sys.argv) == 3: cmd_write(sys.argv[2])
    elif cmd == "rewrite" and len(sys.argv) == 3: cmd_rewrite(sys.argv[2])
    elif cmd == "protect": cmd_protect()
    elif cmd == "unprotect": cmd_unprotect()
    elif cmd == "verify" and len(sys.argv) == 3: cmd_verify(sys.argv[2])
    else: print(__doc__)


if __name__ == "__main__":
    main()
