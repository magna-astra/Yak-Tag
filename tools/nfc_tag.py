#!/usr/bin/env python3
"""
YAK-TAG NFC tag manager — ACR1552U
===================================
Auto-detects NTAG213 / NTAG215 / NTAG216 and uses the right memory map.

    python nfc_tag.py status                 what state is this tag in?
    python nfc_tag.py diag                   raw config dump (troubleshooting)
    python nfc_tag.py wipe                   erase user memory
    python nfc_tag.py write YT-008000        write the tap URL
    python nfc_tag.py rewrite YT-008000      wipe + write onto a used tag
    python nfc_tag.py protect                set write password (REVERSIBLE)
    python nfc_tag.py unprotect              remove the write password
    python nfc_tag.py verify YT-008000

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

CHANGE TAG_PASSWORD BELOW before writing production tags.
"""

import sys

try:
    from smartcard.System import readers
    from smartcard.util import toHexString
except ImportError:
    print("Missing dependency. Run:  pip install pyscard")
    sys.exit(1)

# ============================================================
# CONFIG — change before production
# ============================================================
BASE_URL = "https://magna-astra.github.io/Yak-Tag/t.html?tag="

TAG_PASSWORD = b"YKTG"          # exactly 4 bytes
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


def authenticate(conn, password=TAG_PASSWORD):
    """PWD_AUTH via ACR pseudo-APDU. Returns True on success."""
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
        state["blank"] = all(b == 0x00 for b in raw[:16])
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
        print("Protected but rewritable — will authenticate automatically.")
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
        print(f"\nVerified OK. UID {s['uid']} now points to {tag_code}.")
        print("\nRecord it in the database:")
        print(f"  select record_tag_write('{tag_code}', '{s['uid']}', false);")
    else:
        print(f"\nMISMATCH — read back: {readback}")
        print("Do NOT put this tag on an animal.")


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
    print(f"Password in this script: {TAG_PASSWORD.decode()}")
    if input("Proceed? Type PROTECT: ").strip() != "PROTECT":
        print("Aborted.")
        return

    write_page(conn, prof["pwd"], TAG_PASSWORD)
    write_page(conn, prof["pack"], TAG_PACK + b"\x00\x00")

    cfg0 = bytearray(read_pages(conn, prof["cfg0"], 1))
    cfg0[3] = prof["first_page"]        # protect from first user page onward
    write_page(conn, prof["cfg0"], bytes(cfg0))

    cfg1 = bytearray(read_pages(conn, prof["cfg1"], 1))
    cfg1[0] = cfg1[0] & 0x7F            # PROT=0: write-protect only, stays readable
    write_page(conn, prof["cfg1"], bytes(cfg1))

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


def cmd_verify(tag_code):
    conn = get_connection()
    s = tag_state(conn)
    expected = BASE_URL + tag_code
    print(f"UID:      {s['uid']}")
    print(f"Tag type: {s['profile']['name']}")
    print(f"Expected: {expected}")
    print(f"Found:    {s['url']}")
    print("RESULT: MATCH" if s["url"] == expected else "RESULT: MISMATCH")


def main():
    if len(sys.argv) < 2:
        print(__doc__); return
    cmd = sys.argv[1]
    try:
        if cmd == "status": cmd_status()
        elif cmd == "diag": cmd_diag()
        elif cmd == "wipe": cmd_wipe()
        elif cmd == "write" and len(sys.argv) == 3: cmd_write(sys.argv[2])
        elif cmd == "rewrite" and len(sys.argv) == 3: cmd_rewrite(sys.argv[2])
        elif cmd == "protect": cmd_protect()
        elif cmd == "unprotect": cmd_unprotect()
        elif cmd == "verify" and len(sys.argv) == 3: cmd_verify(sys.argv[2])
        else: print(__doc__)
    except RuntimeError as e:
        print(f"Error: {e}")


if __name__ == "__main__":
    main()
