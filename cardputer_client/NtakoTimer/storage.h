#pragma once
#include <Arduino.h>
#include "types.h"

namespace Storage {
    void    init();

    // ── Auth ──────────────────────────────────────────────────────────────────
    String  getToken();
    String  getEmail();
    void    saveAuth(const char* token, const char* email);
    void    clearAuth();

    // ── Sync ──────────────────────────────────────────────────────────────────
    int64_t getLastSync();
    void    saveLastSync(int64_t ms);

    // ── WiFi & API ────────────────────────────────────────────────────────────
    String  getApiUrl();
    void    saveApiUrl(const char* url);

    // ── Multi-network WiFi ────────────────────────────────────────────────────
    int     getNetworkCount();
    int     getNetworks(WifiNet* list, int maxCount); // returns count
    void    saveNetworks(const WifiNet* list, int count);
    void    addOrUpdateNetwork(const char* ssid, const char* pass); // upsert by SSID
    bool    importLauncherNetworks(); // reads /config.conf from LittleFS

    // ── Beep ─────────────────────────────────────────────────────────────────
    bool    getBeep();          // default true
    void    saveBeep(bool on);

    // ── Alarm & break ─────────────────────────────────────────────────────────
    int     getAlarmMin();      // 0 = disabled, default 0
    int     getBreakMin();      // default 5
    void    saveAlarmBreak(int alarmMin, int breakMin);

    // ── Volume ────────────────────────────────────────────────────────────────
    int     getVolume();        // 0-10, default 8
    void    saveVolume(int v);

    // ── Category persistence (SD/LittleFS binary file) ───────────────────────
    int     loadCategories(Category* cats, int maxCount); // returns count loaded
    void    saveCategories(const Category* cats, int count);

    // ── Task persistence (SD/LittleFS binary file) ────────────────────────────
    int     loadTasks(Task* tasks, int maxCount);  // returns count loaded
    void    saveTasks(const Task* tasks, int count);

    // ── Session log persistence (SD/LittleFS binary file) ─────────────────────
    int     loadSessionLog(SessionEntry* log, int maxCount); // returns count loaded
    bool    saveSessionLog(const SessionEntry* log, int count); // returns false on FS error
}
