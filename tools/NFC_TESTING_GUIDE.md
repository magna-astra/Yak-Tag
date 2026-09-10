# YAK-TAG — Phase 1: NFC tag testing with the ACR1552U

Goal of this phase: prove you can reliably **write a tag_code to a blank
NTAG215, read it back, and lock it** — before any dashboard exists. This
matches your own README's Phase 1 ("field test, tag reliability, read
distance") — do this before building UI on top of it.

The ACR1552U is a **PC/SC-compliant USB reader**, so you don't need the
full ACS SDK for this — `pyscard` talks to it directly like any smart
card reader. That's what `nfc_tool.py` uses.

---

## 1. Install drivers + Python deps

1. Install the ACR1552U driver from ACS's site (Windows/macOS/Linux —
   pick your OS). This registers it as a standard PC/SC reader.
2. Plug in the reader. Its LED should turn on.
3. On your machine:
   ```
   pip install pyscard
   ```
   - Windows: this just works with the driver above.
   - macOS: PC/SC is built in; you may need `brew install pcsc-lite` first.
   - Linux: `sudo apt install pcscd libpcsclite-dev` then `pip install pyscard`.

## 2. Confirm the reader is seen at all

```
python nfc_tool.py detect
```
No tag on the reader yet → you'll get a connection error, that's fine,
it confirms the reader itself is talking to your machine. Now place one
blank NTAG215 flat on the reader and run it again — you should see:
```
Reader OK. Tag present. UID: 04A1B2C3D4E580
```
If you get "No PC/SC reader found," the driver isn't installed correctly
— stop here and fix that first, nothing downstream will work otherwise.

## 3. Read a blank tag

```
python nfc_tool.py read
```
Expect `(empty / unwritten)`. This confirms read APDUs work before you
try writing anything.

## 4. Write a test tag_code

Use a **fake** code first, not a real batch number, so you don't burn a
real `MN-008521` on a typo:
```
python nfc_tool.py write TEST-0001
```
You should see `Wrote N pages.` then `Verified OK: 'TEST-0001'`. The
tool re-reads immediately after writing — if it prints MISMATCH, don't
trust that tag; try a different one before assuming it's a code bug.

## 5. Repeat on 5-10 blank tags

Do this before touching lock. You're testing:
- **Read distance** — how far off the reader's surface does it still
  work? (NFC is short range, a few cm; note it for the muzzle-side
  reader guide once you build the herder app.)
- **Consistency** — does every tag write/verify cleanly first try, or
  do some need 2-3 attempts? That tells you about tag quality before
  you order thousands.
- **UID uniqueness** — confirm no two tags in your batch share a UID
  (extremely unlikely with real NTAG215 stock, but cheap to check: run
  `detect` on each and log the UIDs).

## 6. Locking — read this before you touch it

`nfc_tool.py lock` sets the NTAG215's **hardware lock bits**. This is
different from anything in your Supabase schema — it's a physical
property of the chip itself:

- Once set, **the chip refuses all future writes, forever.** No admin
  password, no factory reset, no software undoes it.
- It does **not** erase what's currently written — it freezes it.
- It only locks the **NFC-writable memory**. Your `tags.status` column
  in Supabase is a separate, independent, reversible flag — locking the
  chip and marking `status='assigned'` in the DB are two different
  actions and you'll want a workflow that does both together later.

For Phase 1:
1. Write + verify on a tag with your fake test code.
2. Only then run `python nfc_tool.py lock` on that **one** tag as a
   dry run of the lock flow itself (types UID + "LOCK" to confirm).
2. Confirm `python nfc_tool.py write anything-else` now fails on that
   tag — that's your proof the lock actually works.
3. Do **not** lock your remaining test tags — you'll want to rewrite
   them as you iterate. Only lock tags right before they go on a real
   cow, once the whole write→photo→lock flow (see below) is built and
   tested end to end.

## 7. What "done" looks like for Phase 1

- [ ] 10+ tags written and verified without a single silent failure
- [ ] Read distance measured and noted (varies with tag design/antenna —
      your README already flags this correctly)
- [ ] Lock tested on 1 tag, confirmed the tag is now read-only
- [ ] UID list logged somewhere so you can cross-check against
      `tags.nfc_uid` once these are registered in Supabase

Once this is solid, the next step is wiring `tag_code` writes to come
from a real `tag_batches` row (so you can never accidentally write a
code outside your reserved range) — that's a small addition to this
same script, not a rebuild.
