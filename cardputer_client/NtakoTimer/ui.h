#pragma once
#include <Arduino.h>
#include "types.h"

namespace UI {
    void init();

    void drawWifiConnecting(const char* ssid, int dots);
    void drawTaskList(const Task* tasks, int count, int selectedIdx,
                      bool syncing, const char* userEmail,
                      const Category* cats = nullptr, int catCount = 0,
                      const int* taskTotalSec = nullptr);
    // Shows elapsed count-up time; breakCountdownSec > 0 shows break timer when paused
    void drawTimer(int elapsedSeconds, const char* taskName, bool paused, int breakCountdownSec = 0);
    void drawLoginEmail   (const char* buf, bool cursor);
    void drawLoginPass    (const char* email, const char* passBuf, bool cursor);
    void drawRegisterEmail(const char* buf, bool cursor);
    void drawRegisterPass (const char* email, const char* passBuf, bool cursor);
    // Category management screens
    void drawCategoryList(const Category* cats, int count, int selectedIdx);
    void drawNewCategoryName(const char* buf, bool cursor);
    void drawCategoryColorPicker(const char* name, int selectedColorIdx);
    // Rename existing category: shows original name + editable input
    void drawRenameCategoryName(const char* originalName, const char* buf, bool cursor);

    // Task creation flow
    void drawNewTaskName(const char* buf, bool cursor);
    void drawNewTaskCategory(const Category* cats, int count, int selectedIdx);

    void drawMessage(const char* msg);

    // WiFi scan screens
    void drawWifiScanning(int dots);
    void drawWifiScanList(const char** ssids, const int* rssis,
                          int count, int selectedIdx);

    // isEdit=true when modifying existing settings (shows current value hint)
    void drawSetupSSID(const char* buf, bool cursor, bool isEdit);
    void drawSetupPass(const char* ssid, const char* buf, bool cursor, bool isEdit);
    void drawSetupApi (const char* buf, bool cursor, bool isEdit);

    // Session history log (one row per session: task name + duration)
    void drawSessionLog(const SessionEntry* entries, int count, int scrollIdx);

    // Task context menu (complete / restore / category / delete)
    void drawTaskAction(const Task& t);

    // Alarm & break & volume setup screens
    void drawSetupAlarmMin(int value);
    void drawSetupBreakMin(int value);
    void drawSetupVolume(int value);   // 0-10

    // Category reassignment for existing task
    void drawEditTaskCategory(const char* taskTitle, const Category* cats, int count, int selectedIdx);

    // Full-screen keybinding reference (page 0 or 1)
    void drawHelp(int page);

    // Read-only task detail view
    // catColorHex: hex string e.g. "#6366f1" or "" for no category
    void drawTaskDetail(const Task& t, const char* catName,
                        const char* catColorHex, int totalSec);
}
