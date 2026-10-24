# YAK-TAG firmware (BLE network, step 2)

Protocol: [`BLE_TAG_SPEC.md`](../BLE_TAG_SPEC.md). Server: `db/schema_v57_ble_network.sql`. Written 2026-10-24 **before the test boards arrived — not built on hardware yet**; expect small fixes on the first build. Not on the website (`_config.yml`).

## `tag-nrf52/` — the tag

Broadcasts `YT-H#####` + battery % every ~1.5 s (non-connectable). The number comes from UICR, written when the tag is programmed, so one build serves every tag.

1. Install **nRF Connect for Desktop → Toolchain Manager → nRF Connect SDK** (any 2.x / 3.x) and **nRF Command Line Tools** (`nrfjprog`).
2. Build: `west build -b nrf52dk/nrf52832 firmware/tag-nrf52` (a nRF52810 beacon: `nrf52dk/nrf52810`; older SDKs write `nrf52dk_nrf52832`).
3. Connect the **nRF52840-DK** by USB; its **Debug out** (P19, 10-pin 1.27 mm) goes to the beacon's SWD pads: SWDIO, SWCLK, VDD, GND. The beacon needs its own battery in (or VDD from the DK).
4. `.\firmware\tag-nrf52\flash_tag.ps1 12` → the beacon is **YT-H00012**.
5. On the horse's page: "📡 BLE таг холбох" → pick YT-H00012. Done.

If the beacon has no 32.768 kHz crystal, uncomment `CONFIG_CLOCK_CONTROL_NRF_K32SRC_RC=y` in `prj.conf` (it won't advertise otherwise).

**Our own tag later (Taiwan):** the nRF52832 itself can be the **NFC tag** (its NFCT peripheral + a small antenna coil on the board) — no separate NFC chip; the record is `https://yaktag.org/t.html?tag=YT-H#####`.

## `listener-esp32/` — the box at a well / winter camp

1. Arduino IDE → Boards Manager → **esp32** (Espressif). Board: **ESP32C3 Dev Module**.
2. App (horses on, `?horses=1` while hidden): 🐎 Адуу → **📶 Сонсогч төхөөрөмж** → standing at the box, name it → **Нэмэх** → copy the key (shown once).
3. In `listener-esp32.ino`: `WIFI_SSID`, `WIFI_PASS` (the camp's hotspot), `YT_KEY`. Upload. Serial Monitor (115200) shows what it hears and the server's answer.
4. Power: USB power bank or a small solar panel + battery. It reports every 60 s; the box's place is the one saved when it was added.

Before production: pin the server's TLS root certificate in the box (it uses `setInsecure()` now).

## `test-tag-esp32/` — a pretend tag for the first day

Two ESP32-C3 SuperMinis test the whole chain before any beacon arrives: one runs `test-tag-esp32.ino` (broadcasts `YT-H00001`, USB / power bank — an ESP32 is no coin-cell tag), the other runs `listener-esp32.ino`. Link YT-H00001 to a test horse ("📡 BLE таг холбох") → within a minute its "Сүүлд харагдсан" moves to the box's place.

## Which beacons to buy for real tags

Prefer models the open-source Everytag project has already flashed over SWD (github.com/vasimv/Everytag): **KKM C2 (nRF52805), KKM P1 / P11 (nRF52810), KKM K4P / K5 (nRF52833), Minew HCB22E (nRF52832)** — all chips our firmware targets. Ask the factory: which nRF chip, SWDIO/SWCLK pads exposed, readout protection on (then only a J-Link-class probe — the nRF52840-DK — can unlock it; an ST-Link clone can't), 32 kHz crystal, price for 5 samples to Taiwan.

## Field test (what to write down)

- Range: walk away from a tag on a horse, note where the phone / box stops hearing it (open steppe, behind the horse's body, in a herd).
- Attachment: collar vs. mane after 2–4 weeks.
- Cold: battery % over the first winter weeks (−30 °C nights).
