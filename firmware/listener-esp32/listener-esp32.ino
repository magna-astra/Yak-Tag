// ============================================================
// YAK-TAG listener box — ESP32-C3 at a well / winter camp
// Protocol: BLE_TAG_SPEC.md (v1). Server: db/schema_v57_ble_network.sql
//
// Hears every YAK-TAG tag nearby (BLE name starting "YT") and, every
// 60 s, reports the strongest reading of each to YAK-TAG
// (rpc/ble_gateway_report) with this box's secret key. The box's place
// was saved when it was added in the app: Миний адуу → 🐎 → 📶 Сонсогч
// төхөөрөмж → Нэмэх (stand at the box). Internet: the camp's phone
// hotspot or Wi-Fi.
//
// Arduino IDE: board "ESP32C3 Dev Module" (esp32 core 2.x or 3.x).
// No extra libraries. Fill in the settings, upload, open Serial Monitor
// (115200) to see what it hears and sends.
//
// NOT YET TESTED on hardware (written 2026-10-24, before the boards
// arrived) — expect small fixes on the first build.
// ============================================================
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <BLEDevice.h>
#include <BLEScan.h>
#include <BLEAdvertisedDevice.h>
#include <map>

// ---------- settings ----------
const char* WIFI_SSID = "CAMP-HOTSPOT";
const char* WIFI_PASS = "password";
const char* YT_KEY    = "ytg_PASTE_THE_KEY_FROM_THE_APP";
const char* YT_URL    = "https://mjijgxfmkgtxmpbmshtl.supabase.co/rest/v1/rpc/ble_gateway_report";
const char* YT_PUBLIC = "sb_publishable_npSJ3ZAWO_ODx_cXbvORoQ__t-_1GiJ";   // the website's public key (config.js)

const uint32_t REPORT_EVERY_MS = 60000;   // spec: every 60 s
const int      SCAN_SECONDS    = 5;       // one scan round
const size_t   MAX_NAMES       = 50;      // server takes 50 per report

struct Heard { int rssi; int battery; };   // battery 255 = unknown
static std::map<String, Heard> heard;      // strongest per tag since the last report
static portMUX_TYPE heardLock = portMUX_INITIALIZER_UNLOCKED;
static uint32_t lastReport = 0;

// One advertisement heard. Protocol v1 manufacturer data:
// FF FF (test company id) · 01 (version) · battery % · flags
class OnHeard : public BLEAdvertisedDeviceCallbacks {
  void onResult(BLEAdvertisedDevice d) override {
    if (!d.haveName()) return;
    String name = String(d.getName().c_str());
    if (!name.startsWith("YT") || name.length() > 40) return;
    int battery = 255;
    if (d.haveManufacturerData()) {
      auto md = d.getManufacturerData();
      if (md.length() >= 5 && (uint8_t)md[0] == 0xFF && (uint8_t)md[1] == 0xFF && (uint8_t)md[2] == 0x01) {
        battery = (uint8_t)md[3];
      }
    }
    int rssi = d.getRSSI();
    portENTER_CRITICAL(&heardLock);
    auto it = heard.find(name);
    if (it == heard.end()) {
      if (heard.size() < MAX_NAMES) heard[name] = { rssi, battery };
    } else {
      if (rssi > it->second.rssi) it->second.rssi = rssi;
      if (battery != 255) it->second.battery = battery;
    }
    portEXIT_CRITICAL(&heardLock);
  }
};

static bool wifiUp() {
  if (WiFi.status() == WL_CONNECTED) return true;
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  for (int i = 0; i < 40 && WiFi.status() != WL_CONNECTED; i++) delay(500);   // up to 20 s
  return WiFi.status() == WL_CONNECTED;
}

static String jsonEscape(const String& s) {
  String o;
  for (size_t i = 0; i < s.length(); i++) {
    char c = s[i];
    if (c == '"' || c == '\\') { o += '\\'; o += c; }
    else if ((uint8_t)c >= 0x20) o += c;
  }
  return o;
}

static void report() {
  std::map<String, Heard> batch;
  portENTER_CRITICAL(&heardLock);
  batch.swap(heard);
  portEXIT_CRITICAL(&heardLock);
  if (batch.empty()) { Serial.println("nothing heard"); return; }

  String body = String("{\"p_key\":\"") + jsonEscape(YT_KEY) + "\",\"p_items\":[";
  bool first = true;
  for (auto& kv : batch) {
    body += first ? "{" : ",{";
    first = false;
    body += "\"name\":\"" + jsonEscape(kv.first) + "\",\"rssi\":" + String(kv.second.rssi);
    if (kv.second.battery != 255) body += ",\"battery\":" + String(kv.second.battery);
    body += "}";
  }
  body += "]}";

  if (!wifiUp()) { Serial.println("no Wi-Fi: this round is lost"); return; }
  WiFiClientSecure tls;
  tls.setInsecure();        // prototype. Before production: pin the server's root certificate.
  HTTPClient http;
  http.setTimeout(15000);
  if (!http.begin(tls, YT_URL)) { Serial.println("http begin failed"); return; }
  http.addHeader("Content-Type", "application/json");
  http.addHeader("apikey", YT_PUBLIC);
  http.addHeader("Authorization", String("Bearer ") + YT_PUBLIC);
  int code = http.POST(body);
  Serial.printf("sent %u tag(s) -> HTTP %d %s\n", (unsigned)batch.size(), code, http.getString().c_str());
  http.end();
}

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println("YAK-TAG listener starting");
  wifiUp();
  BLEDevice::init("");
  BLEScan* scan = BLEDevice::getScan();
  scan->setAdvertisedDeviceCallbacks(new OnHeard(), true);   // true: every advertisement, for the best RSSI
  scan->setActiveScan(false);                                // just listen: no scan requests, less power
  scan->setInterval(100);
  scan->setWindow(99);
  lastReport = millis();
}

void loop() {
  BLEScan* scan = BLEDevice::getScan();
  scan->start(SCAN_SECONDS, false);
  scan->clearResults();
  if (millis() - lastReport >= REPORT_EVERY_MS) {
    lastReport = millis();
    report();
  }
}
