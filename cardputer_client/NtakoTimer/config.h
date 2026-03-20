#pragma once

// ─── NVS storage keys ────────────────────────────────────────────────────────
#define NVS_NS        "ntako"
#define NVS_TOKEN     "jwt"
#define NVS_EMAIL     "email"
#define NVS_LAST_SYNC "last_sync"
// Multi-network keys: wcnt, w0s/w0p … w4s/w4p
#define NVS_WIFI_COUNT "wcnt"
#define NVS_BEEP       "beep"
#define NVS_ALARM_MIN  "alarm_min"
#define NVS_BREAK_MIN  "break_min"
#define NVS_VOLUME     "vol"         // 0-10 (mapped to 0-255 for Speaker)

// ─── Display ─────────────────────────────────────────────────────────────────
#define DISP_W 240
#define DISP_H 135
