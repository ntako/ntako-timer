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
    bool    is_tracker;          // false = pomodoro, true = tracker
    int16_t pomodoro_goal;       // relevant only when is_tracker == false
    int16_t pomodoros_done;
    bool    is_completed;
    int64_t created_at;          // unix ms
    int64_t updated_at;          // unix ms
    bool    needs_push;          // dirty flag — push on next sync
};

enum TimerPhase : uint8_t {
    PHASE_WORK = 0,
    PHASE_SHORT_BREAK,
    PHASE_LONG_BREAK,
};

// One completed session entry (kept in memory, not persisted).
struct SessionEntry {
    char       clientId[37];            // UUID — used for deduplication on merge
    char       taskId[37];              // task client UUID (empty = no task)
    char       taskName[MAX_TITLE_LEN];
    int        durationSec;
    bool       isTracker;               // true = tracking type, false = pomodoro phase
    TimerPhase type;                    // PHASE_WORK / PHASE_SHORT_BREAK / PHASE_LONG_BREAK
};

enum AppState : uint8_t {
    ST_WIFI_CONNECTING,
    ST_LOGIN_EMAIL,
    ST_LOGIN_PASS,
    ST_TASK_LIST,
    ST_TIMER_RUNNING,
    ST_TIMER_PAUSED,
    // Task creation flow: type → name → goal → category
    ST_NEW_TASK_TYPE,           // P=pomodoro / T=tracker
    ST_NEW_TASK_NAME,
    ST_NEW_TASK_GOAL,           // only for pomodoro tasks
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
    ST_SETUP_WORK_MIN,
    ST_SETUP_SHORT_MIN,
    ST_SETUP_LONG_MIN,
    ST_WIFI_SCAN,               // async scan in progress
    ST_WIFI_SCAN_LIST,          // scan results — navigate with j/k
    ST_SESSION_LOG,             // session history — navigate with j/k
    ST_TASK_ACTION,             // context menu overlay: delete / resume
    ST_HELP,                    // keybinding reference overlay
    ST_REGISTER_EMAIL,          // registration — email input
    ST_REGISTER_PASS,           // registration — password input
};
