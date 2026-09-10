#!/usr/bin/env python3
"""
YAK-TAG NFC writer — ACR1552U + NTAG215
========================================
Writes a real NDEF URL record so that tapping the tag with any
phone opens that cow's page — no app install needed.

Install:
    pip install pyscard

Usage:
    python nfc_write.py detect              # confirm reader + tag
    python nfc_write.py read                # show what's on the tag
    python nfc_write.py write YT-008000     # write the tap URL
    python nfc_write.py verify YT-008000
    python nfc_write.py lock                # PERMANENT, see warnings

What gets written:
    https://magna-astra.github.io/Yak-Tag/cow.html?tag=YT-008000

Encoded as an NDEF URI record with the https:// prefix abbreviated
to a single byte (NFC Forum URI abbreviation code 0x04), which saves
8 bytes — worth it on a 504-byte tag.
"""

import sys

try:
    from smartcard.System import readers
    from smartcard.util import toHexString
except ImportError:
    print("Missing dependency. Run:  pip install pyscard")
    sys.exit(1)

# ============================================================
# CHANGE THIS if you move to a custom domain later.
# Keep the trailing '?tag=' — the tag code is appended to it.
# ============================================================
BASE_URL = "https://magna-astra.github.io/Yak-Tag/cow.html?tag="

PAGE_SIZE = 4
FIRST_USER_PAGE = 4
LAST_USER_PAGE = 129
DYNAMIC_LOCK_PAGE = 130

# NFC Forum URI abbreviation codes
URI_PREFIXES = {
    0x01: "http://www.", 0x02: "https://www.",
    0x03: "http://",     0x04: "https://",
}


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


def build_ndef_url(url):
    """Builds a complete NDEF TLV containing one URI record."""
    prefix_code = 0x00
    rest = url
    # longest prefix wins
    for code, prefix in sorted(URI_PREFIXES.items(), key=lambda kv: -len(kv[1])):
        if url.startswith(prefix):
            prefix_code = code
            rest = url[len(prefix):]
            break

    payload = bytes([prefix_code]) + rest.encode("utf-8")

    # NDEF record: MB=1, ME=1, SR=1, TNF=0x01 (well-known)
    header = 0xD1
    type_field = b"U"
    record = bytes([header, len(type_field), len(payload)]) + type_field + payload

    # TLV wrapper: 0x03 = NDEF message, then length, then value, then 0xFE terminator
    if len(record) < 255:
        tlv = bytes([0x03, len(record)]) + record + bytes([0xFE])
    else:
        tlv = bytes([0x03, 0xFF, (len(record) >> 8) & 0xFF, len(record) & 0xFF]) \
              + record + bytes([0xFE])
    return tlv


def parse_ndef_url(raw):
    """Best-effort read of a URI record back off the tag."""
    try:
        if raw[0] != 0x03:
            return None
        if raw[1] == 0xFF:
            length = (raw[2] << 8) | raw[3]
            rec = raw[4:4 + length]
        else:
            length = raw[1]
            rec = raw[2:2 + length]

        type_len = rec[1]
        payload_len = rec[2]
        payload = rec[3 + type_len: 3 + type_len + payload_len]
        prefix = URI_PREFIXES.get(payload[0], "")
        return prefix + payload[1:].decode("utf-8", errors="replace")
    except Exception:
        return None


def cmd_detect():
    conn = get_connection()
    print(f"Reader OK. Tag present. UID: {get_uid(conn)}")


def cmd_read():
    conn = get_connection()
    uid = get_uid(conn)
    raw = read_pages(conn, FIRST_USER_PAGE, 40)
    url = parse_ndef_url(raw)
    print(f"UID: {uid}")
    print(f"URL on tag: {url if url else '(empty / not an NDEF URL)'}")


def cmd_write(tag_code):
    conn = get_connection()
    uid = get_uid(conn)
    url = BASE_URL + tag_code
    tlv = build_ndef_url(url)

    capacity = (LAST_USER_PAGE - FIRST_USER_PAGE + 1) * PAGE_SIZE
    if len(tlv) > capacity:
        print(f"URL too long: needs {len(tlv)} bytes, tag holds {capacity}.")
        return

    print(f"Tag UID:  {uid}")
    print(f"Writing:  {url}")
    print(f"Bytes:    {len(tlv)} of {capacity}")

    blob = tlv + b"\x00" * ((-len(tlv)) % 4)
    page = FIRST_USER_PAGE
    for i in range(0, len(blob), 4):
        write_page(conn, page, blob[i:i + 4])
        page += 1

    readback = parse_ndef_url(read_pages(conn, FIRST_USER_PAGE, 40))
    if readback == url:
        print("Verified OK. Tap this tag with a phone to test.")
    else:
        print(f"MISMATCH — read back: {readback}")
        print("Do not put this tag on an animal.")


def cmd_verify(tag_code):
    conn = get_connection()
    expected = BASE_URL + tag_code
    found = parse_ndef_url(read_pages(conn, FIRST_USER_PAGE, 40))
    print(f"UID:      {get_uid(conn)}")
    print(f"Expected: {expected}")
    print(f"Found:    {found}")
    print("RESULT: MATCH" if found == expected else "RESULT: MISMATCH")


def cmd_lock():
    conn = get_connection()
    uid = get_uid(conn)
    url = parse_ndef_url(read_pages(conn, FIRST_USER_PAGE, 40))

    print("=" * 62)
    print("PERMANENT HARDWARE LOCK — CANNOT BE UNDONE")
    print("The NTAG215 chip will physically refuse all future writes.")
    print("No password, factory reset, or software can reverse this.")
    print("=" * 62)
    print(f"Tag UID: {uid}")
    print(f"Currently holds: {url}")

    if input("Type the UID above to confirm: ").strip().upper() != uid.upper():
        print("UID did not match. Aborted — nothing locked.")
        return
    if input("Type LOCK to proceed: ").strip() != "LOCK":
        print("Aborted — nothing locked.")
        return

    static = bytearray(read_pages(conn, 2, 1))
    static[2] = 0xFF
    static[3] = 0xFF
    write_page(conn, 2, bytes(static))

    dyn = bytearray(read_pages(conn, DYNAMIC_LOCK_PAGE, 1))
    dyn[0] = dyn[1] = dyn[2] = 0xFF
    write_page(conn, DYNAMIC_LOCK_PAGE, bytes(dyn))

    print("Lock bytes written. Verifying...")
    try:
        write_page(conn, FIRST_USER_PAGE, b"\x00\x00\x00\x00")
        print("WARNING: write still succeeded — lock did NOT take effect.")
    except RuntimeError:
        print("Confirmed: tag is now permanently read-only.")


def main():
    if len(sys.argv) < 2:
        print(__doc__); return
    cmd = sys.argv[1]
    if cmd == "detect": cmd_detect()
    elif cmd == "read": cmd_read()
    elif cmd == "write" and len(sys.argv) == 3: cmd_write(sys.argv[2])
    elif cmd == "verify" and len(sys.argv) == 3: cmd_verify(sys.argv[2])
    elif cmd == "lock": cmd_lock()
    else: print(__doc__)


if __name__ == "__main__":
    main()
