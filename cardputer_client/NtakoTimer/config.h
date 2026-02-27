#pragma once

// ─── Timer durations (seconds) ───────────────────────────────────────────────
#define CFG_WORK_SEC        (25 * 60)
#define CFG_SHORT_BREAK_SEC  (5 * 60)
#define CFG_LONG_BREAK_SEC  (15 * 60)
#define CFG_POMODOROS_LONG   4          // pomodoros before a long break

// ─── NVS storage keys ────────────────────────────────────────────────────────
#define NVS_NS        "ntako"
#define NVS_TOKEN     "jwt"
#define NVS_EMAIL     "email"
#define NVS_LAST_SYNC "last_sync"
#define NVS_WORK_MIN  "wmin"
#define NVS_SHORT_MIN "smin"
#define NVS_LONG_MIN  "lmin"
// Multi-network keys: wcnt, w0s/w0p … w4s/w4p
#define NVS_WIFI_COUNT "wcnt"
#define NVS_BEEP       "beep"

// ─── Display ─────────────────────────────────────────────────────────────────
#define DISP_W 240
#define DISP_H 135
