#pragma once
#include <Arduino.h>

#define MAX_CATEGORIES  20
#define MAX_TASKS       20
#define MAX_TITLE_LEN   64
#define MAX_NAME_LEN    32
#define MAX_WIFI_NETS    5
#define MAX_SCAN_NETS   20
#define MAX_SESSION_LOG 30

// ── Predefined colour palette (hex strings, same as Flutter) ──────────────────
#define CAT_COLOR_COUNT 8
static const char* const kCatColors[CAT_COLOR_COUNT] = {
    "#6366f1", // indigo
    "#ec4899", // pink
    "#f59e0b", // amber
    "#10b981", // emerald
    "#3b82f6", // blue
    "#ef4444", // red
    "#8b5cf6", // violet
    "#6b7280", // gray
};

struct WifiNet {
    char ssid[64];
    char pass[64];
};

struct Category {
    char    id[37];              // client UUID (primary key on device)
    int32_t server_id;           // 0 = not yet synced with server
    char    name[MAX_NAME_LEN];
    char    color[8];            // hex string e.g. "#6366f1"
    bool    needs_push;          // dirty flag — push on next sync
};

struct Task {
    char    id[37];              // client UUID (primary key on device)
    int32_t server_id;           // 0 = not yet synced with server
    char    category_id[37];     // empty string = no category
    char    title[MAX_TITLE_LEN];
    bool    is_completed;
    int64_t created_at;          // unix ms
    int64_t updated_at;          // unix ms
    int64_t deleted_at;          // 0 = not deleted
    bool    needs_push;          // dirty flag — push on next sync
};

// One completed session entry (persisted to SD/LittleFS binary file).
struct SessionEntry {
    char       clientId[37];            // UUID — used for deduplication on merge
    char       taskId[37];              // task client UUID (empty = no task)
    char       taskName[MAX_TITLE_LEN];
    int        durationSec;
    int64_t    startedAt;               // unix ms
    int64_t    endedAt;                 // unix ms
    bool       needs_push;              // false once confirmed synced to server
};

// Aggregated task row for the session-log view (one entry per task).
struct TaskSummary {
    char name[MAX_TITLE_LEN];
    char catColor[8];   // hex e.g. "#6366f1"; empty = no category
    int  totalSec;
};

enum AppState : uint8_t {
    ST_WIFI_CONNECTING,
    ST_LOGIN_EMAIL,
    ST_LOGIN_PASS,
    ST_TASK_LIST,
    ST_TIMER_RUNNING,
    ST_TIMER_PAUSED,
    // Task creation flow: name → category
    ST_NEW_TASK_NAME,
    ST_NEW_TASK_CATEGORY,       // select category (or none)
    // Category management
    ST_CATEGORY_LIST,           // j/k navigate, N=new, DEL/D=delete, ESC=back
    ST_NEW_CATEGORY_NAME,
    ST_NEW_CATEGORY_COLOR,      // navigate colour palette with j/k, ENTER=confirm
    // General
    ST_SYNCING,
    ST_MESSAGE,
    ST_SETUP_SSID,
    ST_SETUP_PASS,
    ST_SETUP_API,
    ST_WIFI_SCAN,               // async scan in progress
    ST_WIFI_SCAN_LIST,          // scan results — navigate with j/k
    ST_SESSION_LOG,             // session history — navigate with j/k
    ST_TASK_ACTION,             // context menu overlay: delete / resume
    ST_HELP,                    // keybinding reference overlay
    ST_REGISTER_EMAIL,          // registration — email input
    ST_REGISTER_PASS,           // registration — password input
    ST_SETUP_ALARM_MIN,         // alarm interval setup
    ST_SETUP_BREAK_MIN,         // break duration setup
    ST_SETUP_VOLUME,            // speaker volume setup (0-10)
    ST_EDIT_TASK_CATEGORY,      // category reassignment for existing task
    ST_RENAME_CATEGORY,         // rename existing category (edit name inline)
    ST_TASK_DETAIL,             // read-only detail view for selected task
};
