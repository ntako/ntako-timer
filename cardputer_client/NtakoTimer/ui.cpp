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

// ─── Layout constants ────────────────────────────────────────────────────────
static const int FTR_DIV = DISP_H - 21;
static const int FTR_L1  = DISP_H - 15;
static const int FTR_L2  = DISP_H - 6;
static const int FTR3_DIV = DISP_H - 30;
static const int FTR3_L1  = DISP_H - 23;
static const int FTR3_L2  = DISP_H - 14;
static const int FTR3_L3  = DISP_H - 5;
static const int LST_ROW_H    = 19;
static const int LST_ROW_TOP  = 17;
static const int LST_ROWS     = 6;
static const int LST_ROWS_T   = 5;

// ─── Colour helpers ──────────────────────────────────────────────────────────
static uint32_t parseColor(const char* hex) {
    if (!hex || hex[0] != '#' || strlen(hex) < 7) return C_DGREY;
    char h[7]; memcpy(h, hex + 1, 6); h[6] = '\0';
    return (uint32_t)strtol(h, nullptr, 16);
}

// ─── Battery cache (refresh every 60 s) ──────────────────────────────────────
static int           s_batPct      = -1;
static bool          s_batCharging = false;
static unsigned long s_batLastMs   = 0;

static void refreshBat() {
    unsigned long now = millis();
    if (s_batPct < 0 || now - s_batLastMs >= 60000UL) {
        s_batPct      = M5Cardputer.Power.getBatteryLevel();
        s_batCharging = M5Cardputer.Power.isCharging();
        s_batLastMs   = now;
    }
}

// Draws a tiny battery icon.  rx = right edge x, cy = vertical centre y.
// Body 20×8 px + nub 3×4 px.
static void drawBatteryIcon(int rx, int cy) {
    const int BW = 20, BH = 8, NW = 3, NH = 4;
    int lx = rx - NW - BW;
    int ty = cy - BH / 2;

    uint32_t col = s_batCharging ? C_BLUE
                 : s_batPct >= 50 ? C_GREEN
                 : s_batPct >= 20 ? C_YELLOW
                 :                  C_RED;

    // nub (right terminal)
    canvas.fillRect(rx - NW, cy - NH / 2, NW, NH, col);
    // body outline
    canvas.drawRect(lx, ty, BW, BH, col);
    // fill proportional to charge
    int fillW = max(1, (BW - 2) * s_batPct / 100);
    canvas.fillRect(lx + 1, ty + 1, fillW, BH - 2, col);
    // "+" overlay when charging
    if (s_batCharging) {
        canvas.setTextSize(1);
        canvas.setTextDatum(MC_DATUM);
        canvas.setTextColor(C_BG);
        canvas.drawString("+", lx + BW / 2, cy + 1);
    }
}

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
                      bool syncing, const char* userEmail,
                      const Category* cats, int catCount,
                      const int* taskTotalSec) {
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

    // Battery indicator (icon, cached 60 s)
    refreshBat();
    drawBatteryIcon(DISP_W - 2, 8);

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

            // Thin divider between category groups
            if (i > startRow && strcmp(tasks[i].category_id, tasks[i-1].category_id) != 0)
                canvas.drawFastHLine(0, y, DISP_W, C_XDGREY);

            if (sel) canvas.fillRect(0, y, DISP_W, LST_ROW_H, C_SELROW);

            // Left category color bar (3 px)
            uint32_t catColor = C_DGREY;
            if (cats) {
                for (int c = 0; c < catCount; c++) {
                    if (strcmp(cats[c].id, t.category_id) == 0) {
                        catColor = parseColor(cats[c].color);
                        break;
                    }
                }
            }
            canvas.fillRect(0, y + 1, 3, LST_ROW_H - 2, catColor);

            // Selection cursor
            canvas.setTextDatum(ML_DATUM);
            canvas.setTextColor(sel ? C_RED : C_BG);
            canvas.drawString(">", 5, y + LST_ROW_H / 2);

            // Task title (shorter to leave room for category suffix)
            char trunc[14];
            strlcpy(trunc, t.title, sizeof(trunc));
            canvas.setTextColor(t.is_completed ? C_DGREY : (sel ? C_WHITE : C_GREY));
            canvas.drawString(trunc, 14, y + LST_ROW_H / 2);

            // Category name suffix "|CatName" (up to 8 chars, in grey)
            if (cats && t.category_id[0] != '\0') {
                for (int ci = 0; ci < catCount; ci++) {
                    if (strcmp(cats[ci].id, t.category_id) == 0) {
                        char suf[11]; // "|" + 8 chars + null
                        snprintf(suf, sizeof(suf), "|%.8s", cats[ci].name);
                        int tx = 14 + canvas.textWidth(trunc) + 2;
                        canvas.setTextColor(C_DGREY);
                        canvas.drawString(suf, tx, y + LST_ROW_H / 2);
                        break;
                    }
                }
            }

            // Total tracked time (right side)
            if (taskTotalSec && taskTotalSec[i] > 0) {
                int sec = taskTotalSec[i];
                char dur[10];
                if (sec < 3600)
                    snprintf(dur, sizeof(dur), "%d:%02d", sec / 60, sec % 60);
                else
                    snprintf(dur, sizeof(dur), "%dh%02d", sec / 3600, (sec % 3600) / 60);
                canvas.setTextDatum(MR_DATUM);
                canvas.setTextColor(C_DGREY);
                canvas.drawString(dur, DISP_W - 2, y + LST_ROW_H / 2);
            }
        }
    }

    // Footer hint
    canvas.drawFastHLine(0, FTR_DIV, DISP_W, C_DGREY);
    canvas.setTextDatum(MC_DATUM);
    canvas.setTextColor(C_DGREY);
    canvas.drawString("▼ next  ▲ prev  N new  H help", DISP_W / 2, FTR_L2);

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
    canvas.drawString("[▼▶▲] nav  [N] new  [R] rin.  [D] del  [ESC] back", DISP_W / 2, DISP_H - 6);
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

// ─── Rename category ──────────────────────────────────────────────────────────
void UI::drawRenameCategoryName(const char* originalName, const char* buf, bool cursor) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);
    canvas.setTextDatum(MC_DATUM);

    canvas.setTextColor(C_RED);
    canvas.drawString("Rinomina categoria", DISP_W / 2, 20);

    canvas.setTextColor(C_DGREY);
    char orig[28]; strlcpy(orig, originalName, sizeof(orig));
    canvas.drawString(orig, DISP_W / 2, 42);

    canvas.setTextColor(C_GREY);
    canvas.drawString("Nuovo nome:", DISP_W / 2, 60);

    canvas.setTextColor(C_WHITE);
    String dstr = String(buf) + (cursor ? "_" : " ");
    canvas.drawString(dstr.c_str(), DISP_W / 2, 78);

    canvas.setTextColor(C_DGREY);
    canvas.drawString("[ENTER] salva  [ESC] annulla", DISP_W / 2, 105);
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

    const int SW = 24, SH = 20, GAP = 2;
    const int totalW = CAT_COLOR_COUNT * (SW + GAP) - GAP;
    int startX = (DISP_W - totalW) / 2;
    int swY    = 42;

    for (int i = 0; i < CAT_COLOR_COUNT; i++) {
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
    canvas.drawString("[▼▶▲] pick  [ENTER] confirm", DISP_W / 2, 80);
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

    const int total = count + 1;

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
    canvas.drawString("[▼▶▲] nav  [ENTER] confirm  [ESC] back", DISP_W / 2, DISP_H - 6);
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

// ─── Timer ───────────────────────────────────────────────────────────────────
void UI::drawTimer(int elapsedSeconds, const char* taskName, bool paused, int breakCountdownSec) {
    canvas.fillSprite(C_BG);

    int mm = elapsedSeconds / 60, ss = elapsedSeconds % 60;
    char timebuf[8];
    snprintf(timebuf, sizeof(timebuf), "%02d:%02d", mm, ss);

    // Battery — top-right corner (icon, cached 60 s)
    refreshBat();
    drawBatteryIcon(DISP_W - 2, 6);

    canvas.setTextSize(1);
    canvas.setTextDatum(MC_DATUM);
    canvas.setTextColor(C_GREEN);
    canvas.drawString("TRACKING", DISP_W / 2, 10);

    canvas.setTextSize(3);
    canvas.setTextColor(paused ? C_GREY : C_WHITE);
    canvas.drawString(timebuf, DISP_W / 2, 50);

    canvas.setTextSize(1);

    if (paused && breakCountdownSec > 0) {
        // Show break countdown in orange
        static const uint32_t C_ORANGE = 0xFF8C00;
        canvas.setTextColor(C_ORANGE);
        canvas.drawString("Pausa", DISP_W / 2, 82);
        int bmm = breakCountdownSec / 60, bss = breakCountdownSec % 60;
        char breakbuf[8];
        snprintf(breakbuf, sizeof(breakbuf), "%02d:%02d", bmm, bss);
        canvas.setTextSize(2);
        canvas.setTextColor(C_ORANGE);
        canvas.drawString(breakbuf, DISP_W / 2, 98);
        canvas.setTextSize(1);
    } else if (paused) {
        canvas.setTextColor(C_GREY);
        canvas.drawString("In pausa", DISP_W / 2, 82);
    }

    canvas.setTextColor(C_GREY);
    char trunc[32];
    strlcpy(trunc, taskName, sizeof(trunc));
    canvas.drawString(trunc, DISP_W / 2, 120);

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

        canvas.setTextDatum(ML_DATUM);
        canvas.setTextColor(sel ? C_RED : C_BG);
        canvas.drawString(">", 2, y + LST_ROW_H / 2);

        char trunc[25];
        strlcpy(trunc, ssids[i], sizeof(trunc));
        canvas.setTextColor(sel ? C_WHITE : C_GREY);
        canvas.drawString(trunc, 14, y + LST_ROW_H / 2);

        int rssi   = rssis[i];
        int bx     = DISP_W - 26;
        int by     = y + LST_ROW_H - 3;
        uint32_t bc = (rssi > -65) ? C_GREEN : (rssi > -80 ? C_YELLOW : C_RED);
        canvas.fillRect(bx,      by - 4,  5, 4,  bc);
        if (rssi > -80) canvas.fillRect(bx + 7,  by - 8,  5, 8,  bc);
        if (rssi > -65) canvas.fillRect(bx + 14, by - 12, 5, 12, bc);
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

// ─── Brief message ────────────────────────────────────────────────────────────
void UI::drawMessage(const char* msg) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);
    canvas.setTextDatum(MC_DATUM);
    canvas.setTextColor(C_WHITE);
    canvas.drawString(msg, DISP_W / 2, DISP_H / 2);
    canvas.pushSprite(0, 0);
}

// ─── Session log ─────────────────────────────────────────────────────────────
// Raw view: one row per session, newest first, showing task name + duration.
void UI::drawSessionLog(const SessionEntry* entries, int count, int scrollIdx) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);

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
            int y    = LST_ROW_TOP + (i - scrollIdx) * LST_ROW_H;
            bool sel = (i == scrollIdx);

            if (sel) canvas.fillRect(0, y, DISP_W, LST_ROW_H, C_SELROW);

            // Task name (truncated to fit)
            char trunc[22]; strlcpy(trunc, entries[i].taskName, sizeof(trunc));
            canvas.setTextDatum(ML_DATUM);
            canvas.setTextColor(sel ? C_WHITE : C_GREY);
            canvas.drawString(trunc, 4, y + LST_ROW_H / 2);

            // Duration right-aligned
            int sec = entries[i].durationSec;
            char dur[10];
            if (sec < 3600)
                snprintf(dur, sizeof(dur), "%d:%02d", sec / 60, sec % 60);
            else
                snprintf(dur, sizeof(dur), "%dh%02d", sec / 3600, (sec % 3600) / 60);
            canvas.setTextDatum(MR_DATUM);
            canvas.setTextColor(C_DGREY);
            canvas.drawString(dur, DISP_W - 2, y + LST_ROW_H / 2);
        }
    }

    // Footer
    canvas.drawFastHLine(0, FTR_DIV, DISP_W, C_DGREY);
    canvas.setTextDatum(ML_DATUM);
    canvas.setTextColor(C_DGREY);
    canvas.drawString("[.] giu  [;] su  [ESC] indietro", 2, FTR_L1);
    char pg[12]; snprintf(pg, sizeof(pg), "%d/%d", scrollIdx + 1, count);
    canvas.setTextDatum(MR_DATUM);
    canvas.drawString(pg, DISP_W - 2, FTR_L1);

    canvas.pushSprite(0, 0);
}

// ─── Task action overlay ──────────────────────────────────────────────────────
void UI::drawTaskAction(const Task& t) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);
    canvas.setTextDatum(MC_DATUM);

    canvas.setTextColor(C_RED);
    canvas.drawString("Task Action", DISP_W / 2, 8);
    canvas.drawFastHLine(0, 16, DISP_W, C_DGREY);

    char trunc[32];
    strlcpy(trunc, t.title, sizeof(trunc));
    canvas.setTextColor(C_WHITE);
    canvas.drawString(trunc, DISP_W / 2, 28);

    canvas.setTextColor(t.is_completed ? C_GREEN : C_GREY);
    canvas.drawString(t.is_completed ? "[ complete ]" : "[ active ]", DISP_W / 2, 42);

    canvas.drawFastHLine(0, 52, DISP_W, C_DGREY);

    canvas.setTextColor(C_WHITE);
    canvas.drawString("[D]  segna completo", DISP_W / 2, 65);
    canvas.drawString("[R]  ripristina attivo", DISP_W / 2, 78);
    canvas.drawString("[C]  cambia categoria", DISP_W / 2, 91);
    canvas.setTextColor(C_RED);
    canvas.drawString("[X]  elimina task", DISP_W / 2, 104);

    canvas.setTextColor(C_DGREY);
    canvas.drawString("[ESC] annulla", DISP_W / 2, 120);

    canvas.pushSprite(0, 0);
}

// ─── Setup — Alarm interval ───────────────────────────────────────────────────
void UI::drawSetupAlarmMin(int value) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);
    canvas.setTextDatum(MC_DATUM);

    canvas.setTextColor(C_RED);
    canvas.drawString("Alarm Interval", DISP_W / 2, 18);

    canvas.setTextColor(C_GREY);
    canvas.drawString("Ogni X minuti (0 = off):", DISP_W / 2, 42);

    char valBuf[24];
    if (value == 0)
        strlcpy(valBuf, "Disattivato", sizeof(valBuf));
    else
        snprintf(valBuf, sizeof(valBuf), "Ogni %d min", value);

    canvas.setTextColor(C_WHITE);
    canvas.drawString(valBuf, DISP_W / 2, 65);

    canvas.setTextColor(C_DGREY);
    canvas.drawString("+ / - cambia  ENTER salva  ESC annulla", DISP_W / 2, 105);

    canvas.pushSprite(0, 0);
}

// ─── Setup — Break duration ───────────────────────────────────────────────────
void UI::drawSetupBreakMin(int value) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);
    canvas.setTextDatum(MC_DATUM);

    canvas.setTextColor(C_RED);
    canvas.drawString("Durata Pausa", DISP_W / 2, 18);

    canvas.setTextColor(C_GREY);
    canvas.drawString("Minuti di pausa (0 = off):", DISP_W / 2, 42);

    char valBuf[24];
    if (value == 0)
        strlcpy(valBuf, "Disattivato", sizeof(valBuf));
    else
        snprintf(valBuf, sizeof(valBuf), "%d minuti", value);

    canvas.setTextColor(C_WHITE);
    canvas.drawString(valBuf, DISP_W / 2, 65);

    canvas.setTextColor(C_DGREY);
    canvas.drawString("+ / - cambia  ENTER salva  ESC annulla", DISP_W / 2, 105);

    canvas.pushSprite(0, 0);
}

// ─── Setup — Volume ───────────────────────────────────────────────────────────
void UI::drawSetupVolume(int value) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);
    canvas.setTextDatum(MC_DATUM);

    canvas.setTextColor(C_RED);
    canvas.drawString("Volume", DISP_W / 2, 18);

    canvas.setTextColor(C_GREY);
    canvas.drawString("Livello 0-10:", DISP_W / 2, 42);

    // Bar indicator
    int barW = 160, barH = 10;
    int barX = (DISP_W - barW) / 2, barY = 58;
    canvas.drawRect(barX, barY, barW, barH, C_DGREY);
    int fillW = (value * barW) / 10;
    if (fillW > 0)
        canvas.fillRect(barX, barY, fillW, barH,
                        value <= 3 ? C_BLUE : value <= 7 ? C_GREEN : C_YELLOW);

    char valBuf[8]; snprintf(valBuf, sizeof(valBuf), "%d / 10", value);
    canvas.setTextColor(C_WHITE);
    canvas.drawString(valBuf, DISP_W / 2, 82);

    canvas.setTextColor(C_DGREY);
    canvas.drawString("+ / - cambia  ENTER salva  ESC annulla", DISP_W / 2, 115);

    canvas.pushSprite(0, 0);
}

// ─── Edit task category ───────────────────────────────────────────────────────
void UI::drawEditTaskCategory(const char* taskTitle, const Category* cats, int count, int selectedIdx) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);

    canvas.setTextDatum(ML_DATUM);
    canvas.setTextColor(C_RED);
    canvas.drawString("Cambia categoria", 4, 8);

    canvas.setTextDatum(MC_DATUM);
    canvas.setTextColor(C_DGREY);
    char trunc[28]; strlcpy(trunc, taskTitle, sizeof(trunc));
    canvas.drawString(trunc, DISP_W / 2, 8);

    canvas.drawFastHLine(0, 15, DISP_W, C_DGREY);

    const int total = count + 1;

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
            char catTrunc[24]; strlcpy(catTrunc, cats[i - 1].name, sizeof(catTrunc));
            canvas.setTextColor(sel ? C_WHITE : C_GREY);
            canvas.drawString(catTrunc, 14, y + LST_ROW_H / 2);
        }
    }

    canvas.setTextDatum(MC_DATUM);
    canvas.setTextColor(C_DGREY);
    canvas.drawString("[▼▶▲] nav  [ENTER] confirm  [ESC] back", DISP_W / 2, DISP_H - 6);
    canvas.pushSprite(0, 0);
}

// ─── Help overlay (2 pages) ───────────────────────────────────────────────────
void UI::drawHelp(int page) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);

    // Header
    canvas.setTextDatum(MC_DATUM);
    canvas.setTextColor(C_RED);
    char hdr[32];
    snprintf(hdr, sizeof(hdr), "Help  %d/2  [ESC] chiudi", page + 1);
    canvas.drawString(hdr, DISP_W / 2, 8);
    canvas.drawFastHLine(0, 15, DISP_W, C_DGREY);

    canvas.setTextDatum(ML_DATUM);
    int x = 4, y = 23;

    if (page == 0) {
        // ── Page 1: Task list & Timer ──
        canvas.setTextColor(C_GREY);
        canvas.drawString("Task list", x, y);           y += 9;
        canvas.setTextColor(C_DGREY);
        canvas.drawString("▼▲ nav  ENTER start  N nuovo", x, y); y += 9;
        canvas.drawString("S sync  M categ  O WiFi", x, y);       y += 9;
        canvas.drawString("X azione  H help  W log", x, y);       y += 9;
        canvas.drawString("C impost  A beep  B display", x, y);  y += 13;

        canvas.setTextColor(C_GREY);
        canvas.drawString("Timer", x, y);               y += 9;
        canvas.setTextColor(C_DGREY);
        canvas.drawString("SPC pausa  X stop+salva", x, y);       y += 9;
        canvas.drawString("pausa: break countdown", x, y);        y += 13;

        canvas.setTextColor(C_GREY);
        canvas.drawString("Nuovo task", x, y);          y += 9;
        canvas.setTextColor(C_DGREY);
        canvas.drawString("nome → categoria", x, y);
    } else {
        // ── Page 2: Categorie, WiFi, Session log ──
        canvas.setTextColor(C_GREY);
        canvas.drawString("Categorie", x, y);           y += 9;
        canvas.setTextColor(C_DGREY);
        canvas.drawString("▼▲ nav  N nuova  R rinomina", x, y);   y += 9;
        canvas.drawString("D elimina  ENTER filtro  ESC", x, y);  y += 13;

        canvas.setTextColor(C_GREY);
        canvas.drawString("WiFi / Scan", x, y);         y += 9;
        canvas.setTextColor(C_DGREY);
        canvas.drawString("▼▶▲ nav  ENTER connetti", x, y);       y += 9;
        canvas.drawString("R rescan  T SSID manuale", x, y);      y += 13;

        canvas.setTextColor(C_GREY);
        canvas.drawString("Session log", x, y);         y += 9;
        canvas.setTextColor(C_DGREY);
        canvas.drawString("▼▲ scroll  R ricarica  ESC", x, y);   y += 13;

        canvas.setTextColor(C_GREY);
        canvas.drawString("Impostazioni (menu S)", x, y); y += 9;
        canvas.setTextColor(C_DGREY);
        canvas.drawString("allarme  break  WiFi  API", x, y);
    }

    // Footer: page navigation hint
    canvas.drawFastHLine(0, FTR_DIV, DISP_W, C_DGREY);
    canvas.setTextDatum(MC_DATUM);
    canvas.setTextColor(C_DGREY);
    if (page == 0)
        canvas.drawString("▼ pag. 2  [ESC] chiudi", DISP_W / 2, FTR_L2);
    else
        canvas.drawString("▲ pag. 1  [ESC] chiudi", DISP_W / 2, FTR_L2);

    canvas.pushSprite(0, 0);
}

// ─── Task detail ──────────────────────────────────────────────────────────────
void UI::drawTaskDetail(const Task& t, const char* catName,
                        const char* catColorHex, int totalSec) {
    canvas.fillSprite(C_BG);
    canvas.setTextSize(1);

    // Header
    canvas.setTextDatum(MC_DATUM);
    canvas.setTextColor(C_RED);
    canvas.drawString("Task Detail", DISP_W / 2, 8);
    canvas.drawFastHLine(0, 15, DISP_W, C_DGREY);

    canvas.setTextDatum(ML_DATUM);
    int x = 4, y = 25;

    // Title (up to 36 chars, 2 lines if needed)
    char line1[37]; strlcpy(line1, t.title, sizeof(line1));
    canvas.setTextColor(t.is_completed ? C_DGREY : C_WHITE);
    canvas.drawString(line1, x, y);
    if (strlen(t.title) > 36) {
        y += 10;
        char line2[37]; strlcpy(line2, t.title + 36, sizeof(line2));
        canvas.drawString(line2, x, y);
    }
    y += 14;

    // Category: colour square + name
    canvas.fillRect(x, y - 4, 8, 8, parseColor(catColorHex));
    canvas.setTextColor(C_GREY);
    char cn[28];
    strlcpy(cn, (catName && catName[0]) ? catName : "nessuna categoria", sizeof(cn));
    canvas.drawString(cn, x + 11, y);
    y += 13;

    // Status
    canvas.setTextColor(C_DGREY);
    canvas.drawString("Stato:", x, y);
    canvas.setTextColor(t.is_completed ? C_GREEN : C_GREY);
    canvas.drawString(t.is_completed ? "completato" : "attivo", x + 40, y);
    y += 13;

    // Creation date (unix ms → local time)
    canvas.setTextColor(C_DGREY);
    canvas.drawString("Creato:", x, y);
    char dateBuf[20] = "—";
    if (t.created_at > 1577836800000LL) {
        time_t ts = (time_t)(t.created_at / 1000);
        struct tm* tm_p = localtime(&ts);
        if (tm_p) snprintf(dateBuf, sizeof(dateBuf), "%02d/%02d/%02d %02d:%02d",
                           tm_p->tm_mday, tm_p->tm_mon + 1, tm_p->tm_year % 100,
                           tm_p->tm_hour, tm_p->tm_min);
    }
    canvas.setTextColor(C_GREY);
    canvas.drawString(dateBuf, x + 44, y);
    y += 13;

    // Total tracked time
    canvas.setTextColor(C_DGREY);
    canvas.drawString("Tracciato:", x, y);
    char durBuf[16];
    if (totalSec == 0)          strlcpy(durBuf, "—", sizeof(durBuf));
    else if (totalSec < 3600)   snprintf(durBuf, sizeof(durBuf), "%d min", totalSec / 60);
    else                        snprintf(durBuf, sizeof(durBuf), "%dh %02d min",
                                         totalSec / 3600, (totalSec % 3600) / 60);
    canvas.setTextColor(C_GREY);
    canvas.drawString(durBuf, x + 62, y);
    y += 13;

    // Sync status
    canvas.setTextColor(C_DGREY);
    canvas.drawString("Sync:", x, y);
    char syncBuf[20];
    if (t.server_id > 0) snprintf(syncBuf, sizeof(syncBuf), "server (#%ld)", (long)t.server_id);
    else                 strlcpy(syncBuf, "solo locale", sizeof(syncBuf));
    canvas.setTextColor(t.server_id > 0 ? C_GREEN : C_YELLOW);
    canvas.drawString(syncBuf, x + 32, y);

    // Footer
    canvas.drawFastHLine(0, FTR_DIV, DISP_W, C_DGREY);
    canvas.setTextDatum(MC_DATUM);
    canvas.setTextColor(C_DGREY);
    canvas.drawString("[I] azione  [ESC] indietro", DISP_W / 2, FTR_L2);

    canvas.pushSprite(0, 0);
}
