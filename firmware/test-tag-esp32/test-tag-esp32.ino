// ============================================================
// YAK-TAG TEST tag — an ESP32-C3 (e.g. the "SuperMini") pretending to
// be a horse tag, for testing the listener network before the nRF52
// beacons arrive. Protocol: BLE_TAG_SPEC.md v1 — broadcasts the name
// YT-H00001 + manufacturer data FF FF 01 64 01 (battery "100 %",
// "just restarted") every ~1.5 s, non-connectable.
//
// NOT a real horse tag: an ESP32 drains a coin cell in days. Power it
// from USB or a power bank. Then:
//   1. link YT-H00001 to a test horse: its page → "📡 BLE таг холбох";
//   2. a second ESP32-C3 runs listener-esp32 (or use the app's
//      "📡 Ойролцоох адуу") → the horse's "Сүүлд харагдсан" moves.
//
// Arduino IDE: board "ESP32C3 Dev Module" (esp32 core 2.x or 3.x).
// NOT YET TESTED on the board (written 2026-10-24).
// ============================================================
#include <BLEDevice.h>
#include <BLEAdvertising.h>

const char* TAG_NAME = "YT-H00001";      // change per test tag: YT-H00002 …

// FF FF (test company id) · 01 (version) · 0x64 = 100 % · 01 = just restarted.
// No zero byte inside, so it passes as a plain C string on every core version.
static const char MFG[] = { (char)0xFF, (char)0xFF, 0x01, 0x64, 0x01, 0 };

void setup() {
  Serial.begin(115200);
  BLEDevice::init(TAG_NAME);

  BLEAdvertisementData data;
  data.setFlags(0x06);                   // general discoverable, no classic Bluetooth
  data.setName(TAG_NAME);
  data.setManufacturerData(MFG);

  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->setAdvertisementType(ADV_TYPE_NONCONN_IND);   // broadcast only
  adv->setAdvertisementData(data);
  adv->setScanResponse(false);
  adv->setMinInterval(2400);             // 1500 ms (units of 0.625 ms)
  adv->setMaxInterval(2560);             // 1600 ms
  adv->start();
  Serial.printf("broadcasting %s\n", TAG_NAME);
}

void loop() {
  delay(10000);
}
