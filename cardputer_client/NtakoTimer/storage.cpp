#include <Arduino.h>
#include "storage.h"
#include "config.h"
#include "types.h"
#include <Preferences.h>
#include <LittleFS.h>
#include <SD.h>
#include <SPI.h>
#include <ArduinoJson.h>

static Preferences prefs;

// ─── Filesystem selection (SD preferred, LittleFS fallback) ───────────────────
// M5Cardputer TF card SPI pins (adjust if using a different board):
#define SD_CS   12
#define SD_MOSI 14
#define SD_MISO 39
#define SD_CLK  40

static bool   _sdOk = false;   // set once in Storage::init()

// Returns the active filesystem (SD or LittleFS).
static fs::FS& cfg() {
    return _sdOk ? (fs::FS&)SD : (fs::FS&)LittleFS;
}

// ─── Config file helpers ───────────────────────────────────────────────────────
#define CONFIG_FILE "/ntako_tracker.json"

static void loadConfigDoc(JsonDocument& doc) {
    File f = cfg().open(CONFIG_FILE, "r");
    if (!f) { doc.to<JsonObject>(); return; }
    if (deserializeJson(doc, f)) doc.to<JsonObject>();
    f.close();
}

static void writeConfigDoc(const JsonDocument& doc) {
    File f = cfg().open(CONFIG_FILE, "w");
    if (!f) return;
    serializeJson(doc, f);
    f.close();
}

// ─── Init ─────────────────────────────────────────────────────────────────────
void Storage::init() {
    prefs.begin(NVS_NS, false);

    // Try SD first; keep LittleFS as fallback.
    SPI.begin(SD_CLK, SD_MISO, SD_MOSI, SD_CS);
    _sdOk = SD.begin(SD_CS);
    if (!_sdOk) {
        // true = format on first use if not already formatted
        LittleFS.begin(true);   // mount once, stays mounted
    }
}

// ─── Auth ─────────────────────────────────────────────────────────────────────
String Storage::getToken() {
    JsonDocument doc; loadConfigDoc(doc);
    return String(doc["auth"]["token"] | "");
}
String Storage::getEmail() {
    JsonDocument doc; loadConfigDoc(doc);
    return String(doc["auth"]["email"] | "");
}

void Storage::saveAuth(const char* token, const char* email) {
    JsonDocument doc; loadConfigDoc(doc);
    doc["auth"]["token"] = token;
    doc["auth"]["email"] = email;
    writeConfigDoc(doc);
}

void Storage::clearAuth() {
    JsonDocument doc; loadConfigDoc(doc);
    doc.remove("auth");
    writeConfigDoc(doc);
}

// ─── Sync ─────────────────────────────────────────────────────────────────────
int64_t Storage::getLastSync()          { return prefs.getLong64(NVS_LAST_SYNC, 0LL); }
void    Storage::saveLastSync(int64_t ms) { prefs.putLong64(NVS_LAST_SYNC, ms); }

// ─── Beep ─────────────────────────────────────────────────────────────────────
bool Storage::getBeep()         { return prefs.getBool(NVS_BEEP, true); }
void Storage::saveBeep(bool on) { prefs.putBool(NVS_BEEP, on); }

// ─── Alarm & break ────────────────────────────────────────────────────────────
int  Storage::getAlarmMin()  { return prefs.getInt(NVS_ALARM_MIN, 120); }
int  Storage::getBreakMin()  { return prefs.getInt(NVS_BREAK_MIN, 15); }
void Storage::saveAlarmBreak(int alarmMin, int breakMin) {
    prefs.putInt(NVS_ALARM_MIN, alarmMin);
    prefs.putInt(NVS_BREAK_MIN, breakMin);
}

// ─── Volume ───────────────────────────────────────────────────────────────────
int  Storage::getVolume()    { return prefs.getInt(NVS_VOLUME, 8); }
void Storage::saveVolume(int v) { prefs.putInt(NVS_VOLUME, v); }

// ─── API URL ──────────────────────────────────────────────────────────────────
String Storage::getApiUrl() {
    JsonDocument doc;
    loadConfigDoc(doc);
    return String(doc["api_url"] | "");
}

void Storage::saveApiUrl(const char* url) {
    JsonDocument doc;
    loadConfigDoc(doc);
    doc["api_url"] = url;
    writeConfigDoc(doc);
}

// ─── Multi-network WiFi ───────────────────────────────────────────────────────
int Storage::getNetworkCount() {
    JsonDocument doc;
    loadConfigDoc(doc);
    JsonArray arr = doc["wifi"].as<JsonArray>();
    return arr.isNull() ? 0 : (int) arr.size();
}

int Storage::getNetworks(WifiNet* list, int maxCount) {
    JsonDocument doc;
    loadConfigDoc(doc);
    JsonArray arr = doc["wifi"].as<JsonArray>();
    if (arr.isNull()) return 0;
    int cnt = min((int) arr.size(), maxCount);
    for (int i = 0; i < cnt; i++) {
        strlcpy(list[i].ssid, arr[i]["ssid"] | "", sizeof(list[i].ssid));
        strlcpy(list[i].pass, arr[i]["pass"] | "", sizeof(list[i].pass));
    }
    return cnt;
}

void Storage::saveNetworks(const WifiNet* list, int count) {
    JsonDocument doc;
    loadConfigDoc(doc);                    // preserve api_url and other keys
    JsonArray arr = doc["wifi"].to<JsonArray>();
    int n = min(count, MAX_WIFI_NETS);
    for (int i = 0; i < n; i++) {
        JsonObject obj = arr.add<JsonObject>();
        obj["ssid"] = list[i].ssid;
        obj["pass"] = list[i].pass;
    }
    writeConfigDoc(doc);
}

void Storage::addOrUpdateNetwork(const char* ssid, const char* pass) {
    WifiNet list[MAX_WIFI_NETS];
    int cnt = getNetworks(list, MAX_WIFI_NETS);

    // Update if SSID already exists
    for (int i = 0; i < cnt; i++) {
        if (strcmp(list[i].ssid, ssid) == 0) {
            strlcpy(list[i].pass, pass, sizeof(list[i].pass));
            saveNetworks(list, cnt);
            return;
        }
    }
    // Append (evict oldest if full)
    if (cnt < MAX_WIFI_NETS) {
        strlcpy(list[cnt].ssid, ssid, sizeof(list[cnt].ssid));
        strlcpy(list[cnt].pass, pass, sizeof(list[cnt].pass));
        saveNetworks(list, cnt + 1);
    } else {
        // Shift left, add at end
        for (int i = 0; i < MAX_WIFI_NETS - 1; i++) list[i] = list[i + 1];
        strlcpy(list[MAX_WIFI_NETS - 1].ssid, ssid, sizeof(list[0].ssid));
        strlcpy(list[MAX_WIFI_NETS - 1].pass, pass, sizeof(list[0].pass));
        saveNetworks(list, MAX_WIFI_NETS);
    }
}

// ─── Category persistence (SD/LittleFS binary file) ──────────────────────────
// File format: int32_t count  +  count × sizeof(Category).
#define CATS_FILE  "/ntako_cats.bin"

int Storage::loadCategories(Category* cats, int maxCount) {
    File f = cfg().open(CATS_FILE, "r");
    if (!f) return 0;
    int32_t count = 0;
    f.read((uint8_t*)&count, sizeof(count));
    count = min(count, (int32_t)maxCount);
    size_t expected = sizeof(Category) * count;
    size_t got = (count > 0) ? f.read((uint8_t*)cats, expected) : 0;
    f.close();
    if (count == 0 || got == expected) return (int)count;
    return 0;  // size mismatch → struct changed, discard
}

void Storage::saveCategories(const Category* cats, int count) {
    File f = cfg().open(CATS_FILE, "w");
    if (!f) return;
    int32_t n = (int32_t)count;
    f.write((const uint8_t*)&n, sizeof(n));
    if (count > 0)
        f.write((const uint8_t*)cats, sizeof(Category) * count);
    f.close();
}

// ─── Task persistence (SD/LittleFS binary file) ───────────────────────────────
// File format: int32_t count  +  count × sizeof(Task).
// No NVS blob limit: MAX_TASKS can grow freely.
#define TASKS_FILE "/ntako_tasks.bin"

int Storage::loadTasks(Task* tasks, int maxCount) {
    File f = cfg().open(TASKS_FILE, "r");
    if (!f) return 0;
    int32_t count = 0;
    f.read((uint8_t*)&count, sizeof(count));
    count = min(count, (int32_t)maxCount);
    size_t expected = sizeof(Task) * count;
    size_t got = (count > 0) ? f.read((uint8_t*)tasks, expected) : 0;
    f.close();
    if (count == 0 || got == expected) return (int)count;
    return 0;  // size mismatch → struct changed, discard
}

void Storage::saveTasks(const Task* tasks, int count) {
    File f = cfg().open(TASKS_FILE, "w");
    if (!f) return;
    int32_t n = (int32_t)count;
    f.write((const uint8_t*)&n, sizeof(n));
    if (count > 0)
        f.write((const uint8_t*)tasks, sizeof(Task) * count);
    f.close();
}

// ─── Session log persistence (SD/LittleFS binary file) ───────────────────────
// File format: int32_t count  +  count × sizeof(SessionEntry).
#define SESSION_FILE "/ntako_sessions.bin"

int Storage::loadSessionLog(SessionEntry* log, int maxCount) {
    File f = cfg().open(SESSION_FILE, "r");
    if (!f) return 0;
    int32_t count = 0;
    f.read((uint8_t*)&count, sizeof(count));
    count = min(count, (int32_t)maxCount);
    size_t expected = sizeof(SessionEntry) * count;
    size_t got = (count > 0) ? f.read((uint8_t*)log, expected) : 0;
    f.close();
    if (count == 0 || got == expected) return (int)count;
    return 0;  // size mismatch → struct changed, discard
}

bool Storage::saveSessionLog(const SessionEntry* log, int count) {
    File f = cfg().open(SESSION_FILE, "w");
    if (!f) return false;
    int32_t n = (int32_t)count;
    f.write((const uint8_t*)&n, sizeof(n));
    if (count > 0)
        f.write((const uint8_t*)log, sizeof(SessionEntry) * count);
    f.close();
    return true;
}

bool Storage::importLauncherNetworks() {
    if (!LittleFS.begin(false)) return false;
    File f = LittleFS.open("/config.conf", "r");
    if (!f) { LittleFS.end(); return false; }

    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, f);
    f.close();
    LittleFS.end();

    if (err) return false;

    JsonArray wifiArr = doc[0]["wifi"].as<JsonArray>();
    if (wifiArr.isNull()) return false;

    WifiNet list[MAX_WIFI_NETS];
    int count = 0;
    for (JsonObject n : wifiArr) {
        if (count >= MAX_WIFI_NETS) break;
        const char* s = n["ssid"] | "";
        const char* p = n["pwd"]  | "";
        if (strlen(s) == 0) continue;
        strlcpy(list[count].ssid, s, sizeof(list[count].ssid));
        strlcpy(list[count].pass, p, sizeof(list[count].pass));
        count++;
    }

    if (count > 0) {
        saveNetworks(list, count);
        return true;
    }
    return false;
}
