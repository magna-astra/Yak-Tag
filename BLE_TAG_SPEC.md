# YAK-TAG BLE + NFC tag — protocol v1 (2026-10-24)

The contract between the **tag firmware**, the **listeners** (phones with the YAK-TAG app, ESP32 boxes at wells / winter camps) and the **server** (Supabase, `db/schema_v57_ble_network.sql`). Not on the website (`_config.yml`).

Goal (owner): "like an AirTag" — see where a horse was last heard, online, no subscriptions, all software ours. A BLE tag is only heard within ~50–100 m, so the location comes from **our own listeners**: every phone with the app (later: in the background, also other people's horses) and fixed boxes where horses come to drink.

## 1. What the tag broadcasts (v1 — pilot)

Legacy BLE advertising, non-connectable, **every 1.0–2.0 s**, 0 dBm (raise to +4 dBm only if the field test needs it).

| Field | Bytes | Value |
|---|---|---|
| Flags | 3 | `02 01 06` |
| Complete Local Name | 2 + 9 | `YT-H` + 5 digits, e.g. `YT-H00012` — printed on the tag and in its NFC record |
| Manufacturer Specific Data | 2 + 2 + 3 | company id `0xFFFF` (test value until we own a SIG company id), then `01` (protocol version), battery % (0–100, 255 = unknown), flags (bit 0: just restarted) |

Total 21 of 31 bytes. **The name is the tag's ID**: the server matches it to `cattle.ble_name` (case-insensitive). Ready-made beacons whose name we can set (YT-H…) work with v1 before we flash our own firmware — just without battery %.

The number is written into the chip's UICR (CUSTOMER[0]) when the tag is programmed (`firmware/tag-nrf52/flash_tag.ps1`), so one firmware build serves every tag.

**NFC in the same case** (our own tag): the URL `https://yaktag.org/t.html?tag=YT-H00012` — a tap opens the public page, as with the cow tags. On a nRF52832 the chip itself can be the NFC tag (its NFCT peripheral + an antenna coil on the board); otherwise an NTAG213/215.

## 2. v2 (before mass production): IDs that change

v1's fixed name lets anyone with a scanner app follow one tag over time. v2 keeps the name constant (`YT`) and puts an **8-byte ID that changes every 15 minutes** in the manufacturer data: `02` (version) + `EID = first 8 bytes of AES-128(tag key, slot)`, `slot = floor(unix_time / 900)` as 4 bytes big-endian, zero-padded to 16. The tag's 16-byte key and the time are written once, at registration, over BLE (the app, Web Bluetooth GATT, first 60 s after a battery is put in). The server keeps a table of each tag's EIDs for the slots around now (±1 h for clock drift) and looks sightings up there. Listeners don't change: they report what they hear.

## 3. What a listener sends

Every **60 s** (gateway) or when found (phone), only for names starting with `YT`, the strongest reading per name since the last send:

```json
[{ "name": "YT-H00012", "rssi": -71, "battery": 82, "seen_at": "2026-10-24T09:12:03Z" }]
```

- **Phone** (signed in): `rpc/ble_report` with `p_lat, p_lng, p_accuracy, p_items` — the phone's GPS.
- **ESP32 box** (no login): `rpc/ble_gateway_report` with `p_key` (the box's secret, shown once when it is added) and `p_items` — the box's place is saved with it.
- At most 50 items per call; 120 calls an hour per box / person. Unknown names are ignored.

## 4. What the server does with it

- Matches the name to a horse; keeps **one sighting per horse per listener per 10 minutes** in `ble_sightings` (kept 180 days).
- `ble_sightings` is part of `all_scans`, so **"Сүүлд харагдсан" and the dashboard map move** on their own.
- The horse's card shows the tag's battery and when / where it was last heard.
- A horse reported **lost / stolen** that is heard anywhere → Telegram alert to the owner, the farm's admins and the super admins, with the map link (at most one per 10 minutes).

## 5. Battery and cold (to confirm in the field)

CR2032 ≈ 150 mAh usable with radio bursts; a standard cell is rated to −30 °C, a CR2032L to −40 °C. At 1 s advertising, 0 dBm, a nRF52 averages roughly 10–15 µA → about 1–1.5 years; at 2 s → 2–3 years (estimates). A CR2450 / CR2477 lasts much longer in a thicker case.
