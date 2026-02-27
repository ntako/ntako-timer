#pragma once
#include <Arduino.h>
#include "types.h"

namespace UI {
    void init();

    void drawWifiConnecting(const char* ssid, int dots);
    void drawTaskList(const Task* tasks, int count, int selectedIdx,
                      bool syncing, const char* userEmail, bool trackingMode,
                      const Category* cats = nullptr, int catCount = 0);
    // countUp=true: shows elapsed going up, no progress bar, tracking style
    void drawTimer(TimerPhase phase, int seconds, int total,
                   const char* taskName, int completedPomodoros, bool paused, bool countUp);
    void drawLoginEmail   (const char* buf, bool cursor);
    void drawLoginPass    (const char* email, const char* passBuf, bool cursor);
    void drawRegisterEmail(const char* buf, bool cursor);
    void drawRegisterPass (const char* email, const char* passBuf, bool cursor);
    // Category management screens
    void drawCategoryList(const Category* cats, int count, int selectedIdx);
    void drawNewCategoryName(const char* buf, bool cursor);
    void drawCategoryColorPicker(const char* name, int selectedColorIdx);

    // Task creation flow
    void drawNewTaskType(bool isTracker);         // choose pomodoro / tracker
    void drawNewTaskName(const char* buf, bool cursor);
    void drawNewTaskGoal(const char* name, int goal);
    void drawNewTaskCategory(const Category* cats, int count, int selectedIdx); // -1 = none

    void drawMessage(const char* msg);

    // WiFi scan screens
    void drawWifiScanning(int dots);
    void drawWifiScanList(const char** ssids, const int* rssis,
                          int count, int selectedIdx);

    // isEdit=true when modifying existing settings (shows current value hint)
    void drawSetupSSID(const char* buf, bool cursor, bool isEdit);
    void drawSetupPass(const char* ssid, const char* buf, bool cursor, bool isEdit);
    void drawSetupApi (const char* buf, bool cursor, bool isEdit);

    // Duration setup screens — label e.g. "Work", step = 1/2/3
    void drawDurationScreen(const char* label, int minutes, int step);

    // Session history log
    void drawSessionLog(const SessionEntry* log, int count, int scrollIdx);

    // Task context menu (delete / resume)
    void drawTaskAction(const Task& t);

    // Full-screen keybinding reference
    void drawHelp();
}
