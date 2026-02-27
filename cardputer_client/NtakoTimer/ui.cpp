#include <Arduino.h>
#include "ui.h"
#include "config.h"
#include <M5Cardputer.h>

// Double-buffered sprite to avoid flicker.
static M5Canvas canvas(&M5Cardputer.Display);

// ─── Colours ─────────────────────────────────────────────────────────────────
static const uint32_t C_BG     = 0x111111;
static const uint32_t C_WHITE  = 0xFFFFFF;
static const uint32_t C_GREY   = 0x888888;
static const uint32_t C_DGREY  = 0x444444;
static const uint32_t C_XDGREY = 0x222222;
static const uint32_t C_RED    = 0xE84545;
static const uint32_t C_GREEN  = 0x4CAF50;
static const uint32_t C_BLUE   = 0x2196F3;
static const uint32_t C_YELLOW = 0xFFFF00;
static const uint32_t C_SELROW = 0x2A2A2A;

static uint32_t phaseColor(TimerPhase p) {
    switch (p) {
        case PHASE_WORK:        return C_RED;
        case PHASE_SHORT_BREAK: return C_GREEN;
        case PHASE_LONG_BREAK:  return C_BLUE;
    }
    return C_WHITE;
}

static const char* phaseLabel(TimerPhase p) {
    switch (p) {
        case PHASE_WORK:        return "FOCUS";
        case PHASE_SHORT_BREAK: return "SHORT BREAK";
        case PHASE_LONG_BREAK:  return "LONG BREAK";
    }
    return "";
}

// ─── Layout constants ────────────────────────────────────────────────────────
// Two-line footer (scan list, session log, etc.)
static const int FTR_DIV = DISP_H - 21;   // divider line y
static const int FTR_L1  = DISP_H - 15;   // hint line 1 y
static const int FTR_L2  = DISP_H - 6;    // hint line 2 y
// Three-line footer (task list — many commands)
static const int FTR3_DIV = DISP_H - 30;  // divider line y
static const int FTR3_L1  = DISP_H - 23;  // hint line 1 y
static const int FTR3_L2  = DISP_H - 14;  // hint line 2 y
static const int FTR3_L3  = DISP_H - 5;   // hint line 3 y
static const int LST_ROW_H    = 19;       // row height in list views
static const int LST_ROW_TOP  = 17;       // first row y
static const int LST_ROWS     = 6;        // visible rows (no footer)
static const int LST_ROWS_T   = 5;        // visible rows in task list (1-line footer)

// ─── Init ────────────────────────────────────────────────────────────────────
void UI::init() {
    canvas.createSprite(DISP_W, DISP_H);
}

// ─── WiFi connecting ─────────────────────────────────────────────────────────
void UI::drawWifiConnecting(const char* ssid, int dots) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);
    canvas.setTextDatum(MC_DATUM);

    canvas.setTextColor(C_RED);
    canvas.drawString("NTAKO TIMER", DISP_W / 2, 40);

    char buf[64];
    snprintf(buf, sizeof(buf), "Connecting to %s", ssid);
    canvas.setTextColor(C_GREY);
    canvas.drawString(buf, DISP_W / 2, 65);

    String dotStr = "";
    for (int i = 0; i < dots; i++) dotStr += ".";
    canvas.setTextColor(C_DGREY);
    canvas.drawString(dotStr.c_str(), DISP_W / 2, 82);

    canvas.pushSprite(0, 0);
}

// ─── Task list ───────────────────────────────────────────────────────────────
void UI::drawTaskList(const Task* tasks, int count, int selectedIdx,
                      bool syncing, const char* userEmail, bool trackingMode,
                      const Category* cats, int catCount) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);

    // Header bar
    canvas.setTextColor(C_RED);
    canvas.setTextDatum(ML_DATUM);
    canvas.drawString("NTAKO", 4, 8);

    if (userEmail && strlen(userEmail) > 0) {
        canvas.setTextColor(C_DGREY);
        canvas.drawString(userEmail, 52, 8);
    }

    // Battery indicator — yellow while syncing, red below 20%, dark-grey otherwise
    {
        int  pct      = M5Cardputer.Power.getBatteryLevel();
        bool charging = M5Cardputer.Power.isCharging();
        char batBuf[8];
        snprintf(batBuf, sizeof(batBuf), charging ? "+%d%%" : "%d%%", pct);
        uint32_t col = syncing  ? C_YELLOW
                     : (pct < 20) ? C_RED
                     :              C_DGREY;
        canvas.setTextColor(col);
        canvas.setTextDatum(MR_DATUM);
        canvas.drawString(batBuf, DISP_W - 2, 8);
    }

    canvas.drawFastHLine(0, 15, DISP_W, C_DGREY);

    if (count == 0) {
        canvas.setTextDatum(MC_DATUM);
        canvas.setTextColor(C_GREY);
        canvas.drawString("No tasks", DISP_W / 2, 60);
        canvas.drawString("[N] to create  [L] to login", DISP_W / 2, 76);
    } else {
        int startRow = max(0, selectedIdx - LST_ROWS_T + 1);
        if (selectedIdx < startRow) startRow = selectedIdx;
        int endRow = min(count, startRow + LST_ROWS_T);

        for (int i = startRow; i < endRow; i++) {
            int y = LST_ROW_TOP + (i - startRow) * LST_ROW_H;
            const Task& t = tasks[i];
            bool sel = (i == selectedIdx);

            if (sel) canvas.fillRect(0, y, DISP_W, LST_ROW_H, C_SELROW);

            canvas.setTextDatum(ML_DATUM);
            canvas.setTextColor(sel ? C_RED : C_BG);
            canvas.drawString(">", 2, y + LST_ROW_H / 2);

            // Type badge: P (pomodoro) or T (tracker)
            canvas.setTextColor(t.is_tracker ? C_GREEN : C_RED);
            canvas.drawString(t.is_tracker ? "T" : "P", 10, y + LST_ROW_H / 2);

            char trunc[24];
            strlcpy(trunc, t.title, sizeof(trunc));
            canvas.setTextColor(t.is_completed ? C_DGREY : C_WHITE);
            canvas.drawString(trunc, 22, y + LST_ROW_H / 2);

            // Right side: pomodoro progress or tracker indicator
            canvas.setTextDatum(MR_DATUM);
            if (!t.is_tracker) {
                char prog[10];
                snprintf(prog, sizeof(prog), "%d/%d", t.pomodoros_done, t.pomodoro_goal);
                canvas.setTextColor(t.pomodoros_done >= t.pomodoro_goal ? C_GREEN : C_RED);
                canvas.drawString(prog, DISP_W - 2, y + LST_ROW_H / 2);
            } else {
                canvas.setTextColor(C_GREY);
                canvas.drawString("~", DISP_W - 2, y + LST_ROW_H / 2);
            }
        }
    }

    // Footer hint
    canvas.drawFastHLine(0, FTR_DIV, DISP_W, C_DGREY);
    canvas.setTextDatum(MC_DATUM);
    canvas.setTextColor(C_DGREY);
    canvas.drawString(". next  ; prev  N new  H help", DISP_W / 2, FTR_L2);

    canvas.pushSprite(0, 0);
}

// ─── Category list ────────────────────────────────────────────────────────────
void UI::drawCategoryList(const Category* cats, int count, int selectedIdx) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);

    canvas.setTextDatum(ML_DATUM);
    canvas.setTextColor(C_RED);
    canvas.drawString("Categories", 4, 8);

    char cntBuf[10];
    snprintf(cntBuf, sizeof(cntBuf), "%d", count);
    canvas.setTextColor(C_DGREY);
    canvas.setTextDatum(MR_DATUM);
    canvas.drawString(cntBuf, DISP_W - 2, 8);

    canvas.drawFastHLine(0, 15, DISP_W, C_DGREY);

    if (count == 0) {
        canvas.setTextDatum(MC_DATUM);
        canvas.setTextColor(C_GREY);
        canvas.drawString("No categories", DISP_W / 2, 60);
        canvas.drawString("[N] to create", DISP_W / 2, 76);
    } else {
        int startRow = max(0, selectedIdx - LST_ROWS + 1);
        if (selectedIdx < startRow) startRow = selectedIdx;
        int endRow = min(count, startRow + LST_ROWS);

        for (int i = startRow; i < endRow; i++) {
            int y = LST_ROW_TOP + (i - startRow) * LST_ROW_H;
            bool sel = (i == selectedIdx);
            if (sel) canvas.fillRect(0, y, DISP_W, LST_ROW_H, C_SELROW);

            canvas.setTextDatum(ML_DATUM);
            canvas.setTextColor(sel ? C_RED : C_BG);
            canvas.drawString(">", 2, y + LST_ROW_H / 2);

            char trunc[28];
            strlcpy(trunc, cats[i].name, sizeof(trunc));
            canvas.setTextColor(sel ? C_WHITE : C_GREY);
            canvas.drawString(trunc, 14, y + LST_ROW_H / 2);
        }
    }

    canvas.setTextDatum(MC_DATUM);
    canvas.setTextColor(C_DGREY);
    canvas.drawString("[./;] nav  [N] new  [D] del  [FN] back", DISP_W / 2, DISP_H - 6);
    canvas.pushSprite(0, 0);
}

// ─── New category — name ──────────────────────────────────────────────────────
void UI::drawNewCategoryName(const char* buf, bool cursor) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);
    canvas.setTextDatum(MC_DATUM);

    canvas.setTextColor(C_RED);
    canvas.drawString("New Category", DISP_W / 2, 20);

    canvas.setTextColor(C_GREY);
    canvas.drawString("Name:", DISP_W / 2, 48);

    canvas.setTextColor(C_WHITE);
    String dstr = String(buf) + (cursor ? "_" : " ");
    canvas.drawString(dstr.c_str(), DISP_W / 2, 66);

    canvas.setTextColor(C_DGREY);
    canvas.drawString("[ENTER] next  [ESC] cancel", DISP_W / 2, 105);
    canvas.pushSprite(0, 0);
}

// ─── New category — colour picker ─────────────────────────────────────────────
void UI::drawCategoryColorPicker(const char* name, int selectedColorIdx) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);
    canvas.setTextDatum(MC_DATUM);

    canvas.setTextColor(C_RED);
    canvas.drawString("Choose Colour", DISP_W / 2, 10);

    canvas.setTextColor(C_DGREY);
    char trunc[24]; strlcpy(trunc, name, sizeof(trunc));
    canvas.drawString(trunc, DISP_W / 2, 24);

    // Draw colour swatches (8 in a row, 26px each)
    const int SW = 24, SH = 20, GAP = 2;
    const int totalW = CAT_COLOR_COUNT * (SW + GAP) - GAP;
    int startX = (DISP_W - totalW) / 2;
    int swY    = 42;

    for (int i = 0; i < CAT_COLOR_COUNT; i++) {
        // Parse hex colour to 16-bit 565
        const char* hex = kCatColors[i];
        long rgb = strtol(hex + 1, nullptr, 16);
        uint16_t r = (rgb >> 16) & 0xFF;
        uint16_t g = (rgb >>  8) & 0xFF;
        uint16_t b =  rgb        & 0xFF;
        uint16_t col565 = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);

        int sx = startX + i * (SW + GAP);
        canvas.fillRect(sx, swY, SW, SH, col565);

        if (i == selectedColorIdx) {
            canvas.drawRect(sx - 1, swY - 1, SW + 2, SH + 2, C_WHITE);
        }
    }

    canvas.setTextColor(C_DGREY);
    canvas.drawString("[./;] pick  [ENTER] confirm", DISP_W / 2, 80);
    canvas.pushSprite(0, 0);
}

// ─── New task — type selection ────────────────────────────────────────────────
void UI::drawNewTaskType(bool isTracker) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);
    canvas.setTextDatum(MC_DATUM);

    canvas.setTextColor(C_WHITE);
    canvas.drawString("New Task — Type", DISP_W / 2, 18);

    // Pomodoro option
    canvas.setTextColor(isTracker ? C_DGREY : C_RED);
    canvas.drawString(!isTracker ? "> Pomodoro <" : "  Pomodoro  ", DISP_W / 2, 52);
    canvas.setTextColor(C_DGREY);
    canvas.drawString("countdown to goal", DISP_W / 2, 63);

    // Tracker option
    canvas.setTextColor(isTracker ? C_GREEN : C_DGREY);
    canvas.drawString(isTracker ? "> Tracker <" : "  Tracker  ", DISP_W / 2, 82);
    canvas.setTextColor(C_DGREY);
    canvas.drawString("freeform count-up", DISP_W / 2, 93);

    canvas.setTextColor(C_DGREY);
    canvas.drawString("[./;] nav  [ENTER] confirm  [FN] back", DISP_W / 2, 118);
    canvas.pushSprite(0, 0);
}

// ─── New task — category selection ───────────────────────────────────────────
void UI::drawNewTaskCategory(const Category* cats, int count, int selectedIdx) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);

    canvas.setTextDatum(ML_DATUM);
    canvas.setTextColor(C_RED);
    canvas.drawString("New Task — Category", 4, 8);
    canvas.drawFastHLine(0, 15, DISP_W, C_DGREY);

    // -1 = no category (first item in list)
    // 0..count-1 = actual categories
    const int total = count + 1;  // include "None" at index 0

    int startRow = max(0, selectedIdx - LST_ROWS + 1);
    if (selectedIdx < startRow) startRow = selectedIdx;
    int endRow = min(total, startRow + LST_ROWS);

    for (int i = startRow; i < endRow; i++) {
        int y = LST_ROW_TOP + (i - startRow) * LST_ROW_H;
        bool sel = (i == selectedIdx);
        if (sel) canvas.fillRect(0, y, DISP_W, LST_ROW_H, C_SELROW);

        canvas.setTextDatum(ML_DATUM);
        canvas.setTextColor(sel ? C_RED : C_BG);
        canvas.drawString(">", 2, y + LST_ROW_H / 2);

        if (i == 0) {
            canvas.setTextColor(sel ? C_WHITE : C_GREY);
            canvas.drawString("-- None --", 14, y + LST_ROW_H / 2);
        } else {
            char trunc[24]; strlcpy(trunc, cats[i - 1].name, sizeof(trunc));
            canvas.setTextColor(sel ? C_WHITE : C_GREY);
            canvas.drawString(trunc, 14, y + LST_ROW_H / 2);
        }
    }

    canvas.setTextDatum(MC_DATUM);
    canvas.setTextColor(C_DGREY);
    canvas.drawString("[./;] nav  [ENTER] confirm  [FN] back", DISP_W / 2, DISP_H - 6);
    canvas.pushSprite(0, 0);
}

// ─── Timer ───────────────────────────────────────────────────────────────────
void UI::drawTimer(TimerPhase phase, int seconds, int total,
                   const char* taskName, int completedPomodoros, bool paused, bool countUp) {
    canvas.fillSprite(C_BG);

    int mm = seconds / 60, ss = seconds % 60;
    char timebuf[8];
    snprintf(timebuf, sizeof(timebuf), "%02d:%02d", mm, ss);

    // Battery — top-right corner
    {
        int  pct      = M5Cardputer.Power.getBatteryLevel();
        bool charging = M5Cardputer.Power.isCharging();
        char batBuf[8];
        snprintf(batBuf, sizeof(batBuf), charging ? "+%d%%" : "%d%%", pct);
        canvas.setTextSize(1);
        canvas.setTextDatum(TR_DATUM);
        canvas.setTextColor(pct < 20 ? C_RED : C_DGREY);
        canvas.drawString(batBuf, DISP_W - 2, 2);
    }

    if (countUp) {
        // ── Tracking mode ──
        canvas.setTextSize(1);
        canvas.setTextDatum(MC_DATUM);
        canvas.setTextColor(C_GREEN);
        canvas.drawString("TRACKING", DISP_W / 2, 10);

        canvas.setTextSize(3);
        canvas.setTextColor(paused ? C_GREY : C_WHITE);
        canvas.drawString(timebuf, DISP_W / 2, 62);

        canvas.setTextSize(1);
        canvas.setTextColor(C_GREY);
        char trunc[32];
        strlcpy(trunc, taskName, sizeof(trunc));
        canvas.drawString(trunc, DISP_W / 2, 106);

    } else {
        // ── Pomodoro mode ──
        uint32_t col = phaseColor(phase);

        canvas.setTextSize(1);
        canvas.setTextDatum(MC_DATUM);
        char header[32];
        snprintf(header, sizeof(header), "%s  (%d done)", phaseLabel(phase), completedPomodoros);
        canvas.setTextColor(col);
        canvas.drawString(header, DISP_W / 2, 10);

        canvas.setTextSize(3);
        canvas.setTextColor(paused ? C_GREY : C_WHITE);
        canvas.drawString(timebuf, DISP_W / 2, 62);

        const int BAR_X = 20, BAR_Y = 92, BAR_W = 200, BAR_H = 5;
        float prog = (total > 0) ? (float)(total - seconds) / (float)total : 0.0f;
        canvas.fillRect(BAR_X, BAR_Y, BAR_W, BAR_H, C_XDGREY);
        if (prog > 0.0f)
            canvas.fillRect(BAR_X, BAR_Y, (int)(BAR_W * prog), BAR_H, col);

        canvas.setTextSize(1);
        canvas.setTextColor(C_GREY);
        char trunc[32];
        strlcpy(trunc, taskName, sizeof(trunc));
        canvas.drawString(trunc, DISP_W / 2, 106);

    }

    canvas.pushSprite(0, 0);
}

// ─── Login — email ───────────────────────────────────────────────────────────
void UI::drawLoginEmail(const char* buf, bool cursor) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);
    canvas.setTextDatum(MC_DATUM);

    canvas.setTextColor(C_RED);
    canvas.drawString("NTAKO TIMER  —  Login", DISP_W / 2, 15);

    canvas.setTextColor(C_GREY);
    canvas.drawString("Email:", DISP_W / 2, 42);

    canvas.setTextColor(C_WHITE);
    String display = String(buf) + (cursor ? "_" : " ");
    canvas.drawString(display.c_str(), DISP_W / 2, 60);

    canvas.setTextColor(C_DGREY);
    canvas.drawString("[ENTER] ok  [R] register  [ESC] back", DISP_W / 2, 95);

    canvas.pushSprite(0, 0);
}

// ─── Login — password ────────────────────────────────────────────────────────
void UI::drawLoginPass(const char* email, const char* passBuf, bool cursor) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);
    canvas.setTextDatum(MC_DATUM);

    canvas.setTextColor(C_RED);
    canvas.drawString("NTAKO TIMER  —  Login", DISP_W / 2, 15);

    canvas.setTextColor(C_DGREY);
    canvas.drawString(email, DISP_W / 2, 30);

    canvas.setTextColor(C_GREY);
    canvas.drawString("Password:", DISP_W / 2, 52);

    String passDisplay = String(passBuf) + (cursor ? "_" : " ");
    canvas.setTextColor(C_WHITE);
    canvas.drawString(passDisplay.c_str(), DISP_W / 2, 70);

    canvas.setTextColor(C_DGREY);
    canvas.drawString("[ENTER] login", DISP_W / 2, 100);

    canvas.pushSprite(0, 0);
}

// ─── Register — email ─────────────────────────────────────────────────────────
void UI::drawRegisterEmail(const char* buf, bool cursor) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);
    canvas.setTextDatum(MC_DATUM);

    canvas.setTextColor(C_GREEN);
    canvas.drawString("NTAKO TIMER  —  Register", DISP_W / 2, 15);

    canvas.setTextColor(C_GREY);
    canvas.drawString("Email:", DISP_W / 2, 42);

    canvas.setTextColor(C_WHITE);
    String display = String(buf) + (cursor ? "_" : " ");
    canvas.drawString(display.c_str(), DISP_W / 2, 60);

    canvas.setTextColor(C_DGREY);
    canvas.drawString("[ENTER] next  [ESC] cancel", DISP_W / 2, 95);

    canvas.pushSprite(0, 0);
}

// ─── Register — password ──────────────────────────────────────────────────────
void UI::drawRegisterPass(const char* email, const char* passBuf, bool cursor) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);
    canvas.setTextDatum(MC_DATUM);

    canvas.setTextColor(C_GREEN);
    canvas.drawString("NTAKO TIMER  —  Register", DISP_W / 2, 15);

    canvas.setTextColor(C_DGREY);
    canvas.drawString(email, DISP_W / 2, 30);

    canvas.setTextColor(C_GREY);
    canvas.drawString("Password (min 8 chars):", DISP_W / 2, 52);

    String passDisplay = String(passBuf) + (cursor ? "_" : " ");
    canvas.setTextColor(C_WHITE);
    canvas.drawString(passDisplay.c_str(), DISP_W / 2, 70);

    canvas.setTextColor(C_DGREY);
    canvas.drawString("[ENTER] create account  [ESC] back", DISP_W / 2, 100);

    canvas.pushSprite(0, 0);
}

// ─── New task — name ─────────────────────────────────────────────────────────
void UI::drawNewTaskName(const char* buf, bool cursor) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);
    canvas.setTextDatum(MC_DATUM);

    canvas.setTextColor(C_WHITE);
    canvas.drawString("New Task", DISP_W / 2, 20);

    canvas.setTextColor(C_GREY);
    canvas.drawString("Name:", DISP_W / 2, 48);

    canvas.setTextColor(C_WHITE);
    const char* display = buf;
    int len = strlen(buf);
    if (len > 26) display = buf + len - 26;
    String dstr = String(display) + (cursor ? "_" : " ");
    canvas.drawString(dstr.c_str(), DISP_W / 2, 66);

    canvas.setTextColor(C_DGREY);
    canvas.drawString("[ENTER] next  [ESC] cancel", DISP_W / 2, 105);

    canvas.pushSprite(0, 0);
}

// ─── New task — goal ─────────────────────────────────────────────────────────
void UI::drawNewTaskGoal(const char* name, int goal) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);
    canvas.setTextDatum(MC_DATUM);

    canvas.setTextColor(C_WHITE);
    canvas.drawString("New Task", DISP_W / 2, 18);

    canvas.setTextColor(C_DGREY);
    char trunc[32];
    strlcpy(trunc, name, sizeof(trunc));
    canvas.drawString(trunc, DISP_W / 2, 34);

    canvas.setTextColor(C_GREY);
    canvas.drawString("Pomodoro goal:", DISP_W / 2, 58);

    canvas.setTextSize(2);
    canvas.setTextColor(C_RED);
    char buf[4];
    snprintf(buf, sizeof(buf), "%d", goal);
    canvas.drawString(buf, DISP_W / 2, 82);

    canvas.pushSprite(0, 0);
}

// ─── Duration setup ───────────────────────────────────────────────────────────
void UI::drawDurationScreen(const char* label, int minutes, int step) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);
    canvas.setTextDatum(MC_DATUM);

    canvas.setTextColor(C_RED);
    canvas.drawString("Timer Durations", DISP_W / 2, 12);

    canvas.setTextColor(C_GREY);
    canvas.drawString(label, DISP_W / 2, 34);

    canvas.setTextSize(3);
    canvas.setTextColor(C_WHITE);
    char buf[4];
    snprintf(buf, sizeof(buf), "%d", minutes);
    canvas.drawString(buf, DISP_W / 2, 68);

    canvas.setTextSize(1);
    canvas.setTextColor(C_DGREY);
    canvas.drawString("min", DISP_W / 2, 98);

    char stepBuf[4];
    snprintf(stepBuf, sizeof(stepBuf), "%d/3", step);
    canvas.drawString(stepBuf, DISP_W / 2, 126);

    canvas.pushSprite(0, 0);
}

// ─── WiFi scanning (spinner) ─────────────────────────────────────────────────
void UI::drawWifiScanning(int dots) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);
    canvas.setTextDatum(MC_DATUM);

    canvas.setTextColor(C_RED);
    canvas.drawString("NTAKO TIMER", DISP_W / 2, 30);

    canvas.setTextColor(C_WHITE);
    canvas.drawString("Scanning WiFi", DISP_W / 2, 60);

    String dotStr = "";
    for (int i = 0; i < (dots % 4); i++) dotStr += ".";
    canvas.setTextColor(C_DGREY);
    canvas.drawString(dotStr.c_str(), DISP_W / 2, 76);

    canvas.pushSprite(0, 0);
}

// ─── WiFi scan list ───────────────────────────────────────────────────────────
void UI::drawWifiScanList(const char** ssids, const int* rssis,
                          int count, int selectedIdx) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);

    // Header
    canvas.setTextColor(C_RED);
    canvas.setTextDatum(ML_DATUM);
    canvas.drawString("WiFi Scan", 4, 8);

    char cntBuf[10];
    snprintf(cntBuf, sizeof(cntBuf), "%d nets", count);
    canvas.setTextColor(C_DGREY);
    canvas.setTextDatum(MR_DATUM);
    canvas.drawString(cntBuf, DISP_W - 2, 8);

    canvas.drawFastHLine(0, 15, DISP_W, C_DGREY);

    if (count == 0) {
        canvas.setTextColor(C_DGREY);
        canvas.setTextDatum(MC_DATUM);
        canvas.drawString("No networks found", DISP_W / 2, LST_ROW_TOP + LST_ROW_H);
        canvas.drawString("Press R to scan again", DISP_W / 2, LST_ROW_TOP + LST_ROW_H * 2);
    }

    int startRow = max(0, selectedIdx - LST_ROWS + 1);
    if (selectedIdx < startRow) startRow = selectedIdx;
    int endRow = min(count, startRow + LST_ROWS);

    for (int i = startRow; i < endRow; i++) {
        int y = LST_ROW_TOP + (i - startRow) * LST_ROW_H;
        bool sel = (i == selectedIdx);

        if (sel) canvas.fillRect(0, y, DISP_W, LST_ROW_H, C_SELROW);

        // Cursor
        canvas.setTextDatum(ML_DATUM);
        canvas.setTextColor(sel ? C_RED : C_BG);
        canvas.drawString(">", 2, y + LST_ROW_H / 2);

        // SSID (truncated to ~24 chars)
        char trunc[25];
        strlcpy(trunc, ssids[i], sizeof(trunc));
        canvas.setTextColor(sel ? C_WHITE : C_GREY);
        canvas.drawString(trunc, 14, y + LST_ROW_H / 2);

        // Signal bars — 3 rectangles of increasing height on the right
        int rssi   = rssis[i];
        int bx     = DISP_W - 26;
        int by     = y + LST_ROW_H - 3;
        uint32_t bc = (rssi > -65) ? C_GREEN : (rssi > -80 ? C_YELLOW : C_RED);
        // bar 1 (weak): always shown
        canvas.fillRect(bx,      by - 4,  5, 4,  bc);
        // bar 2 (medium): if rssi > -80
        if (rssi > -80)
            canvas.fillRect(bx + 7,  by - 8,  5, 8,  bc);
        // bar 3 (strong): if rssi > -65
        if (rssi > -65)
            canvas.fillRect(bx + 14, by - 12, 5, 12, bc);
    }

    canvas.pushSprite(0, 0);
}

// ─── Setup — SSID ────────────────────────────────────────────────────────────
void UI::drawSetupSSID(const char* buf, bool cursor, bool isEdit) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);
    canvas.setTextDatum(MC_DATUM);

    canvas.setTextColor(C_RED);
    canvas.drawString(isEdit ? "Settings" : "First Setup", DISP_W / 2, 12);

    canvas.setTextColor(C_GREY);
    canvas.drawString("WiFi SSID:", DISP_W / 2, 38);

    canvas.setTextColor(C_WHITE);
    String display = String(buf) + (cursor ? "_" : " ");
    canvas.drawString(display.c_str(), DISP_W / 2, 56);

    canvas.setTextColor(C_DGREY);
    canvas.drawString("[ENTER] next  [ESC] cancel", DISP_W / 2, 100);
    canvas.drawString("1/3", DISP_W / 2, 120);

    canvas.pushSprite(0, 0);
}

// ─── Setup — WiFi password ────────────────────────────────────────────────────
void UI::drawSetupPass(const char* ssid, const char* buf, bool cursor, bool isEdit) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);
    canvas.setTextDatum(MC_DATUM);

    canvas.setTextColor(C_RED);
    canvas.drawString(isEdit ? "Settings" : "First Setup", DISP_W / 2, 12);

    canvas.setTextColor(C_DGREY);
    canvas.drawString(ssid, DISP_W / 2, 27);

    canvas.setTextColor(C_GREY);
    canvas.drawString("WiFi Password:", DISP_W / 2, 46);

    String passDisplay = String(buf) + (cursor ? "_" : " ");
    canvas.setTextColor(C_WHITE);
    canvas.drawString(passDisplay.c_str(), DISP_W / 2, 64);

    canvas.setTextColor(C_DGREY);
    canvas.drawString("[ENTER] next  [ESC] back", DISP_W / 2, 100);
    canvas.drawString("2/3", DISP_W / 2, 120);

    canvas.pushSprite(0, 0);
}

// ─── Setup — API URL ─────────────────────────────────────────────────────────
void UI::drawSetupApi(const char* buf, bool cursor, bool isEdit) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);
    canvas.setTextDatum(MC_DATUM);

    canvas.setTextColor(C_RED);
    canvas.drawString(isEdit ? "Settings" : "First Setup", DISP_W / 2, 12);

    canvas.setTextColor(C_GREY);
    canvas.drawString("API URL (no trailing /):", DISP_W / 2, 35);

    canvas.setTextColor(C_WHITE);
    // Show last 28 chars if long
    const char* display = buf;
    int len = strlen(buf);
    if (len > 28) display = buf + len - 28;
    String dstr = String(display) + (cursor ? "_" : " ");
    canvas.drawString(dstr.c_str(), DISP_W / 2, 55);

    canvas.setTextColor(C_DGREY);
    canvas.drawString("e.g. https://yourdomain.com/api", DISP_W / 2, 75);
    canvas.drawString("[ENTER] save  [ESC] back", DISP_W / 2, 100);
    canvas.drawString("3/3", DISP_W / 2, 120);

    canvas.pushSprite(0, 0);
}

// ─── Brief message ───────────────────────────────────────────────────────────
// ─── Session log ─────────────────────────────────────────────────────────────
void UI::drawSessionLog(const SessionEntry* log, int count, int scrollIdx) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);

    // Header
    canvas.setTextDatum(MC_DATUM);
    canvas.setTextColor(C_RED);
    canvas.drawString("Session Log", DISP_W / 2, 8);
    canvas.drawFastHLine(0, 15, DISP_W, C_DGREY);

    if (count == 0) {
        canvas.setTextColor(C_GREY);
        canvas.drawString("No sessions yet", DISP_W / 2, 65);
    } else {
        int endRow = min(count, scrollIdx + LST_ROWS);

        for (int i = scrollIdx; i < endRow; i++) {
            // Most-recent-first: index 0 is newest
            int y    = LST_ROW_TOP + (i - scrollIdx) * LST_ROW_H;
            bool sel = (i == scrollIdx);
            if (sel) canvas.fillRect(0, y, DISP_W, LST_ROW_H, C_SELROW);

            // Type badge: W / S / L
            const char* badge = (log[i].type == PHASE_WORK)        ? "W"
                               : (log[i].type == PHASE_SHORT_BREAK) ? "S" : "L";
            uint16_t badgeCol = (log[i].type == PHASE_WORK) ? C_RED : C_GREEN;
            canvas.setTextDatum(ML_DATUM);
            canvas.setTextColor(badgeCol);
            canvas.drawString(badge, 4, y + LST_ROW_H / 2);

            // Task name (truncated)
            char trunc[22]; strlcpy(trunc, log[i].taskName, sizeof(trunc));
            canvas.setTextColor(C_WHITE);
            canvas.drawString(trunc, 16, y + LST_ROW_H / 2);

            // Duration: MM:SS or H:MM:SS
            int sec = log[i].durationSec;
            char dur[10];
            if (sec < 3600)
                snprintf(dur, sizeof(dur), "%02d:%02d", sec / 60, sec % 60);
            else
                snprintf(dur, sizeof(dur), "%d:%02d:%02d", sec / 3600, (sec % 3600) / 60, sec % 60);
            canvas.setTextDatum(MR_DATUM);
            canvas.setTextColor(C_DGREY);
            canvas.drawString(dur, DISP_W - 2, y + LST_ROW_H / 2);
        }
    }

    canvas.pushSprite(0, 0);
}

// ─── Task action overlay ──────────────────────────────────────────────────────
void UI::drawTaskAction(const Task& t) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);
    canvas.setTextDatum(MC_DATUM);

    canvas.setTextColor(C_RED);
    canvas.drawString("Task Action", DISP_W / 2, 10);
    canvas.drawFastHLine(0, 18, DISP_W, C_DGREY);

    // Task name
    char trunc[32];
    strlcpy(trunc, t.title, sizeof(trunc));
    canvas.setTextColor(C_WHITE);
    canvas.drawString(trunc, DISP_W / 2, 36);

    // Status
    canvas.setTextColor(t.is_completed ? C_GREEN : C_GREY);
    canvas.drawString(t.is_completed ? "[ complete ]" : "[ active ]", DISP_W / 2, 52);

    // Progress
    char prog[20];
    snprintf(prog, sizeof(prog), "%d / %d pomodoros", t.pomodoros_done, t.pomodoro_goal);
    canvas.setTextColor(C_DGREY);
    canvas.drawString(prog, DISP_W / 2, 66);

    canvas.drawFastHLine(0, 76, DISP_W, C_DGREY);

    canvas.setTextColor(C_WHITE);
    canvas.drawString("[D]  mark complete  (hide task)", DISP_W / 2, 92);
    canvas.drawString("[R]  mark active  (restore task)", DISP_W / 2, 107);

    canvas.setTextColor(C_DGREY);
    canvas.drawString("[ESC] cancel", DISP_W / 2, 125);

    canvas.pushSprite(0, 0);
}

// ─── Help overlay ─────────────────────────────────────────────────────────────
void UI::drawHelp() {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);

    canvas.setTextDatum(MC_DATUM);
    canvas.setTextColor(C_RED);
    canvas.drawString("NTAKO — Help  [FN] chiudi", DISP_W / 2, 8);
    canvas.drawFastHLine(0, 15, DISP_W, C_DGREY);

    canvas.setTextDatum(ML_DATUM);
    int x = 4, y = 23;

    canvas.setTextColor(C_GREY);
    canvas.drawString("Task list", x, y);  y += 9;
    canvas.setTextColor(C_DGREY);
    canvas.drawString(". next  ; prev  ENTER start  N new", x, y);  y += 9;
    canvas.drawString("C categorie  S sync  L login", x, y);          y += 9;
    canvas.drawString("O WiFi  D durate  H help  W log", x, y);      y += 9;
    canvas.drawString("A beep  B display  X azione task", x, y);    y += 13;

    canvas.setTextColor(C_GREY);
    canvas.drawString("Nuovo task", x, y);  y += 9;
    canvas.setTextColor(C_DGREY);
    canvas.drawString("./; tipo  nome  [goal]  categoria", x, y);   y += 13;

    canvas.setTextColor(C_GREY);
    canvas.drawString("Categorie", x, y);  y += 9;
    canvas.setTextColor(C_DGREY);
    canvas.drawString("j/k nav  N nuova  D elimina", x, y);        y += 9;
    canvas.drawString("ENTER filtro task  FN annulla", x, y);       y += 13;

    canvas.setTextColor(C_GREY);
    canvas.drawString("Timer", x, y);  y += 9;
    canvas.setTextColor(C_DGREY);
    canvas.drawString("SPC/ENTER pausa   X stop+salva", x, y);     y += 13;

    canvas.setTextColor(C_GREY);
    canvas.drawString("WiFi scan", x, y);  y += 9;
    canvas.setTextColor(C_DGREY);
    canvas.drawString("j/k  ENTER pick  T manuale  R scan", x, y);

    canvas.pushSprite(0, 0);
}

void UI::drawMessage(const char* msg) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);
    canvas.setTextDatum(MC_DATUM);
    canvas.setTextColor(C_WHITE);
    canvas.drawString(msg, DISP_W / 2, DISP_H / 2);
    canvas.pushSprite(0, 0);
}
