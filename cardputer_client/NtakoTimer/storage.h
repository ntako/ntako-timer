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

    // ── Timer durations ───────────────────────────────────────────────────────
    int     getWorkMin();   // default 25
    int     getShortMin();  // default 5
    int     getLongMin();   // default 15
    void    saveDurations(int work, int shortB, int longB);

    // ── Category persistence (NVS blob) ──────────────────────────────────────
    int     loadCategories(Category* cats, int maxCount); // returns count loaded
    void    saveCategories(const Category* cats, int count);

    // ── Task persistence (NVS blob) ───────────────────────────────────────────
    int     loadTasks(Task* tasks, int maxCount);  // returns count loaded
    void    saveTasks(const Task* tasks, int count);
}
