/*
 * NTAKO Timer — M5Stack Cardputer client
 *
 * ── Arduino IDE 2.x settings ──────────────────────────────────────────────
 *  Board Manager URL : https://m5stack.oss-cn-shenzhen.aliyuncs.com/resource/arduino/package_m5stack_index.json
 *  Board            : M5Stack > M5Stack-Cardputer
 *  USB Mode         : Hardware CDC and JTAG
 *  USB CDC On Boot  : Enabled
 *  Partition Scheme : Huge APP (3MB No OTA/1MB SPIFFS)  ← REQUIRED, sketch > 1.3 MB
 *  Upload Speed     : 1500000
 *
 * ── Libraries (Library Manager) ──────────────────────────────────────────
 *  M5Cardputer   >= 1.0.0   (by M5Stack)
 *  ArduinoJson   >= 7.0.0   (by Benoit Blanchon)
 *
 * ── Key bindings (task list) ──────────────────────────────────────────────
 *  .  next task    ;  prev task   ENTER  start timer
 *  N      new task (→ tipo → name → [goal] → category)
 *  C      categorie (./; nav  N new  D delete  ENTER filter)
 *  S      sync                    L      login
 *  O      WiFi scan / add network D      durate timer
 *  H      keybinding help         W      session log
 *  A      beep on/off             B      display on/off
 *  (timer)    SPC/ENTER pause     X      stop + salva
 *  (scan)     ./; nav  ENTER pick  T manual SSID  R rescan
 *  (categorie) N nuova  D elimina  ENTER filtro task  FN annulla
 * ─────────────────────────────────────────────────────────────────────────
 */

#include <M5Cardputer.h>
#include <WiFi.h>
#include <time.h>
#include <esp_system.h>

#include "config.h"
#include "types.h"
#include "storage.h"
#include "api_client.h"
#include "timer_logic.h"
#include "ui.h"

// ─── Global state ─────────────────────────────────────────────────────────────
static AppState appState  = ST_WIFI_CONNECTING;
static AppState prevState = ST_TASK_LIST;

static Category categories[MAX_CATEGORIES];
static int      catCount      = 0;
static int      selectedCat   = 0;   // index in category list screen

static Task  tasks[MAX_TASKS];
static int   taskCount    = 0;
static int   selectedTask = 0;

static char  jwtToken[512] = "";
static char  userEmail[64] = "";

// ── Mode ──────────────────────────────────────────────────────────────────────
static bool trackingMode = false;   // false = Pomodoro, true = Tracking (count-up)

// ── Input buffers — auth ──────────────────────────────────────────────────────
static char  inputEmail[64]               = "";
static char  inputPass[64]                = "";

// ── Input buffers — new task ──────────────────────────────────────────────────
static char  inputTaskName[MAX_TITLE_LEN] = "";
static int   inputTaskGoal                = 4;
static bool  inputTaskIsTracker           = false;
static int   inputTaskCatIdx              = 0;   // 0 = none, 1..catCount = category

// ── Input buffers — new category ─────────────────────────────────────────────
static char  inputCatName[MAX_NAME_LEN]   = "";
static int   inputCatColorIdx             = 0;

// ── Input buffers — setup / settings ─────────────────────────────────────────
static char  inputSSID[64]    = "";
static char  inputWPass[64]   = "";
static char  inputApiUrl[128] = "";
static bool  isEditingSettings = false;
static bool  displayOn         = true;
static const uint8_t BRIGHTNESS_ON = 128;
static bool  beepEnabled       = true;

// ── Duration setup buffers ────────────────────────────────────────────────────
static int   setupWorkMin  = 25;
static int   setupShortMin = 5;
static int   setupLongMin  = 15;

// ── Active session ────────────────────────────────────────────────────────────
static char    activeSessionId[37] = "";
static int     activeTaskIdx       = -1;
static int64_t sessionStartedAt    = 0;
static int     sessionDurationSec  = 0;

// ── Transient message ─────────────────────────────────────────────────────────
static char          messageText[80] = "";
static unsigned long messageUntilMs  = 0;

// ── WiFi ──────────────────────────────────────────────────────────────────────
static char          wifiSSID[64]  = "";
static unsigned long wifiStartMs   = 0;
static unsigned long lastWifiDotMs = 0;
static int           wifiDots      = 0;

// ── Multi-network WiFi ────────────────────────────────────────────────────────
static WifiNet       knownNets[MAX_WIFI_NETS];
static int           autoConnectCount = 0;
static int           autoConnectIdx   = 0;

// ── WiFi scan results ─────────────────────────────────────────────────────────
static char      scanSSIDs[MAX_SCAN_NETS][64];
static int       scanRSSI[MAX_SCAN_NETS];
static int       scanCount       = 0;
static int       scanSelectedIdx = 0;
static const char* scanSSIDPtrs[MAX_SCAN_NETS];

// ── Session log (in-memory, newest at index 0) ────────────────────────────────
static SessionEntry  sessionLog[MAX_SESSION_LOG];
static int           sessionLogCount  = 0;
static int           sessionLogScroll = 0;

static void pushSessionLog(const char* clientId, const char* taskName,
                            int durationSec, TimerPhase type, bool isTracker) {
    int n = min(sessionLogCount, MAX_SESSION_LOG - 1);
    for (int i = n; i > 0; i--) sessionLog[i] = sessionLog[i - 1];
    strlcpy(sessionLog[0].clientId,  clientId,  sizeof(sessionLog[0].clientId));
    strlcpy(sessionLog[0].taskName,  taskName,  sizeof(sessionLog[0].taskName));
    sessionLog[0].durationSec = durationSec;
    sessionLog[0].isTracker   = isTracker;
    sessionLog[0].type        = type;
    if (sessionLogCount < MAX_SESSION_LOG) sessionLogCount++;
    sessionLogScroll = 0;
}

// ── Cursor blink ──────────────────────────────────────────────────────────────
static bool          cursorVisible    = true;
static unsigned long lastCursorToggle = 0;

// ─── Utilities ────────────────────────────────────────────────────────────────
static int64_t nowMs() {
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    return (int64_t)tv.tv_sec * 1000LL + tv.tv_usec / 1000LL;
}

static void generateUUID(char* buf) {
    uint8_t b[16];
    for (int i = 0; i < 16; i++) b[i] = (uint8_t)(esp_random() & 0xFF);
    b[6] = (b[6] & 0x0F) | 0x40;
    b[8] = (b[8] & 0x3F) | 0x80;
    snprintf(buf, 37,
        "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        b[0],b[1],b[2],b[3], b[4],b[5], b[6],b[7],
        b[8],b[9], b[10],b[11],b[12],b[13],b[14],b[15]);
}

static void showMessage(const char* msg, unsigned long durationMs = 2000) {
    strlcpy(messageText, msg, sizeof(messageText));
    messageUntilMs = millis() + durationMs;
    prevState = (appState != ST_MESSAGE) ? appState : prevState;
    appState  = ST_MESSAGE;
    UI::drawMessage(msg);
}

// ─── Sync ─────────────────────────────────────────────────────────────────────
static Category     _incomingCats[MAX_CATEGORIES];
static Task         _incoming[MAX_TASKS];
static SessionEntry _incomingSessions[MAX_SESSION_LOG];
static SessionEntry _localOnly[MAX_SESSION_LOG];

static bool pullFromServer(bool /*forceFull*/ = false) {
    if (strlen(jwtToken) == 0) return false;

    int64_t since      = 0;
    int64_t serverTime = 0;
    int     inCatCount = 0;
    int     sesCount   = 0;

    int n = Api::pull(jwtToken, since,
                      _incomingCats, MAX_CATEGORIES, inCatCount,
                      _incoming, MAX_TASKS, serverTime,
                      _incomingSessions, MAX_SESSION_LOG, &sesCount);
    if (n < 0) return false;

    // ── Merge categories ──
    for (int i = 0; i < inCatCount; i++) {
        bool found = false;
        for (int j = 0; j < catCount; j++) {
            if (strcmp(categories[j].id, _incomingCats[i].id) == 0) {
                categories[j] = _incomingCats[i];
                found = true;
                break;
            }
        }
        if (!found && catCount < MAX_CATEGORIES)
            categories[catCount++] = _incomingCats[i];
    }
    // Remove categories deleted on other devices
    {
        int newCount = 0;
        for (int j = 0; j < catCount; j++) {
            bool keep = categories[j].needs_push;
            if (!keep) {
                for (int i = 0; i < inCatCount; i++) {
                    if (strcmp(categories[j].id, _incomingCats[i].id) == 0) {
                        keep = true; break;
                    }
                }
            }
            if (keep) categories[newCount++] = categories[j];
        }
        catCount = newCount;
    }

    // ── Merge tasks ──
    for (int i = 0; i < n; i++) {
        bool found = false;
        for (int j = 0; j < taskCount; j++) {
            if (strcmp(tasks[j].id, _incoming[i].id) == 0) {
                tasks[j] = _incoming[i];
                found = true;
                break;
            }
        }
        if (!found && taskCount < MAX_TASKS)
            tasks[taskCount++] = _incoming[i];
    }
    {
        int newCount = 0;
        for (int j = 0; j < taskCount; j++) {
            bool keep = tasks[j].needs_push;
            if (!keep) {
                for (int i = 0; i < n; i++) {
                    if (strcmp(tasks[j].id, _incoming[i].id) == 0) {
                        keep = true; break;
                    }
                }
            }
            if (keep) tasks[newCount++] = tasks[j];
        }
        taskCount = newCount;
    }

    // ── Merge session log ──
    if (sesCount > 0) {
        int localOnlyCount = 0;
        for (int i = 0; i < sessionLogCount; i++) {
            bool foundOnServer = false;
            if (strlen(sessionLog[i].clientId) > 0) {
                for (int j = 0; j < sesCount; j++) {
                    if (strcmp(sessionLog[i].clientId, _incomingSessions[j].clientId) == 0) {
                        foundOnServer = true;
                        break;
                    }
                }
            }
            if (!foundOnServer && localOnlyCount < MAX_SESSION_LOG)
                _localOnly[localOnlyCount++] = sessionLog[i];
        }

        sessionLogCount  = 0;
        sessionLogScroll = 0;

        for (int i = 0; i < sesCount && sessionLogCount < MAX_SESSION_LOG; i++) {
            SessionEntry& se = sessionLog[sessionLogCount];
            strlcpy(se.clientId, _incomingSessions[i].clientId, sizeof(se.clientId));
            strlcpy(se.taskId,   _incomingSessions[i].taskId,   sizeof(se.taskId));
            se.durationSec = _incomingSessions[i].durationSec;
            se.isTracker   = _incomingSessions[i].isTracker;
            se.type        = _incomingSessions[i].type;
            // Resolve taskId to title
            bool resolved = false;
            for (int j = 0; j < taskCount; j++) {
                if (strcmp(tasks[j].id, _incomingSessions[i].taskId) == 0) {
                    strlcpy(se.taskName, tasks[j].title, sizeof(se.taskName));
                    resolved = true;
                    break;
                }
            }
            if (!resolved) strlcpy(se.taskName, "?", sizeof(se.taskName));
            sessionLogCount++;
        }

        for (int i = 0; i < localOnlyCount && sessionLogCount < MAX_SESSION_LOG; i++)
            sessionLog[sessionLogCount++] = _localOnly[i];
    }

    if (serverTime > 0) Storage::saveLastSync(serverTime);
    if (selectedTask >= taskCount) selectedTask = max(0, taskCount - 1);
    return true;
}

static void doSync() {
    if (strlen(jwtToken) == 0) { showMessage("Not logged in"); return; }
    AppState saved = appState;
    appState = ST_SYNCING;
    UI::drawTaskList(tasks, taskCount, selectedTask, true, userEmail, trackingMode,
                     categories, catCount);

    // 1. Push unsynced categories
    for (int i = 0; i < catCount; i++) {
        if (categories[i].needs_push)
            Api::pushCategory(jwtToken, categories[i]);
    }
    Storage::saveCategories(categories, catCount);

    // 2. Push locally-modified tasks
    int  pushOk = 0, pushFail = 0;
    char firstErr[52] = "";
    for (int i = 0; i < taskCount; i++) {
        if (tasks[i].needs_push) {
            char err[52] = "";
            if (Api::pushTask(jwtToken, tasks[i], err, sizeof(err))) {
                pushOk++;
            } else {
                if (pushFail == 0) strlcpy(firstErr, err, sizeof(firstErr));
                pushFail++;
            }
        }
    }

    // 3. Pull and merge server state
    bool pulled = pullFromServer();

    // 4. Persist locally
    Storage::saveCategories(categories, catCount);
    Storage::saveTasks(tasks, taskCount);

    appState = saved;

    char msg[64];
    if (pushFail > 0 && firstErr[0] != '\0')
        snprintf(msg, sizeof(msg), "Err: %.58s", firstErr);
    else if (pushFail > 0)
        snprintf(msg, sizeof(msg), "Sync: %d ok, %d failed!", pushOk, pushFail);
    else if (!pulled)
        strlcpy(msg, "Pull failed — check server", sizeof(msg));
    else
        snprintf(msg, sizeof(msg), "Sync OK (%d tasks)", taskCount);
    showMessage(msg);
}

// ─── WiFi ─────────────────────────────────────────────────────────────────────
static void startWifiNet(const WifiNet& net) {
    strlcpy(wifiSSID, net.ssid, sizeof(wifiSSID));
    WiFi.disconnect(true);
    WiFi.mode(WIFI_STA);
    WiFi.begin(net.ssid, net.pass);
    wifiStartMs   = millis();
    lastWifiDotMs = 0;
    wifiDots      = 0;
    appState      = ST_WIFI_CONNECTING;
}

static void startWifiScan() {
    WiFi.disconnect(true);
    WiFi.mode(WIFI_STA);
    WiFi.scanNetworks(true);
    scanSelectedIdx = 0;
    scanCount       = 0;
    lastWifiDotMs   = 0;
    wifiDots        = 0;
    appState        = ST_WIFI_SCAN;
}

// ─── Timer ────────────────────────────────────────────────────────────────────
static int durationForPhase(TimerPhase p) {
    switch (p) {
        case PHASE_WORK:        return Storage::getWorkMin()  * 60;
        case PHASE_SHORT_BREAK: return Storage::getShortMin() * 60;
        case PHASE_LONG_BREAK:  return Storage::getLongMin()  * 60;
    }
    return Storage::getWorkMin() * 60;
}

static void startTimer(int taskIdx) {
    activeTaskIdx    = taskIdx;
    sessionStartedAt = nowMs();
    generateUUID(activeSessionId);

    // If selected task is a tracker task, override trackingMode
    bool useTracking = trackingMode;
    if (taskIdx >= 0 && taskIdx < taskCount && tasks[taskIdx].is_tracker)
        useTracking = true;

    if (useTracking) {
        sessionDurationSec = 0;
        Timer::startCountUp();
    } else {
        sessionDurationSec = durationForPhase(Timer::currentPhase);
        Timer::start(sessionDurationSec);
    }
    appState = ST_TIMER_RUNNING;
}

static void beepDone() {
    if (!beepEnabled) return;
    M5Cardputer.Speaker.tone(880,  150); delay(200);
    M5Cardputer.Speaker.tone(880,  150); delay(200);
    M5Cardputer.Speaker.tone(1320, 350); delay(400);
}

static void completeTimer() {
    int64_t endedAt = nowMs();

    if (strlen(jwtToken) > 0 && activeTaskIdx >= 0 && activeTaskIdx < taskCount) {
        const char* typeStr = (Timer::currentPhase == PHASE_WORK)        ? "work"
                            : (Timer::currentPhase == PHASE_SHORT_BREAK) ? "short_break"
                                                                          : "long_break";
        Api::pushSession(jwtToken, activeSessionId,
                         tasks[activeTaskIdx].id, typeStr,
                         sessionStartedAt, endedAt, sessionDurationSec);

        if (Timer::currentPhase == PHASE_WORK) {
            tasks[activeTaskIdx].pomodoros_done++;
            tasks[activeTaskIdx].updated_at = endedAt;
            tasks[activeTaskIdx].needs_push = true;
            Api::pushTask(jwtToken, tasks[activeTaskIdx]);
            Storage::saveTasks(tasks, taskCount);
        }
    }

    beepDone();

    const char* taskName = (activeTaskIdx >= 0 && activeTaskIdx < taskCount)
                           ? tasks[activeTaskIdx].title : "—";
    pushSessionLog(activeSessionId, taskName, sessionDurationSec, Timer::currentPhase, false);

    TimerPhase next = Timer::advancePhase();
    Timer::stop();
    appState = ST_TASK_LIST;

    const char* msg = (next == PHASE_WORK) ? "Break done — focus time!"
                                           : "Pomodoro done — break time!";
    showMessage(msg);
}

static void completeTrackingSession() {
    int elapsed     = Timer::elapsedSeconds();
    int64_t endedAt = nowMs();

    bool syncOk = false;
    if (elapsed > 0 && strlen(jwtToken) > 0
        && activeTaskIdx >= 0 && activeTaskIdx < taskCount) {
        if (tasks[activeTaskIdx].needs_push)
            Api::pushTask(jwtToken, tasks[activeTaskIdx]);
        syncOk = Api::pushSession(jwtToken, activeSessionId,
                                  tasks[activeTaskIdx].id, "tracking",
                                  sessionStartedAt, endedAt, elapsed);
    }

    if (elapsed > 0) {
        const char* taskName = (activeTaskIdx >= 0 && activeTaskIdx < taskCount)
                               ? tasks[activeTaskIdx].title : "—";
        pushSessionLog(activeSessionId, taskName, elapsed, PHASE_WORK, true);
    }

    Timer::stop();
    appState = ST_TASK_LIST;

    char msg[40];
    int mm = elapsed / 60, ss = elapsed % 60;
    if (!syncOk && WiFi.status() == WL_CONNECTED && strlen(jwtToken) > 0)
        snprintf(msg, sizeof(msg), "Tracked %02d:%02d (no sync!)", mm, ss);
    else
        snprintf(msg, sizeof(msg), "Tracked %02d:%02d", mm, ss);
    showMessage(msg);
}

// ─── Keyboard helpers ─────────────────────────────────────────────────────────
static void appendChar(char* buf, size_t bufSize, char c) {
    int len = strlen(buf);
    if (len < (int)bufSize - 1) { buf[len] = c; buf[len + 1] = '\0'; }
}

static void backspace(char* buf) {
    int len = strlen(buf);
    if (len > 0) buf[len - 1] = '\0';
}

// ─── Keyboard handlers ────────────────────────────────────────────────────────

static void onKeyTaskList(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) {
        switch (c) {
            case '.':
                if (selectedTask < taskCount - 1) selectedTask++; break;
            case ';':
                if (selectedTask > 0) selectedTask--;             break;
            case 'n': case 'N':
                // New task: start with type selection
                inputTaskIsTracker = false;
                appState = ST_NEW_TASK_TYPE;
                break;
            case 'c': case 'C':
                selectedCat = 0;
                appState = ST_CATEGORY_LIST;
                break;
            case 's': case 'S': doSync(); break;
            case 'l': case 'L':
                inputEmail[0] = '\0'; inputPass[0] = '\0';
                appState = ST_LOGIN_EMAIL; break;
            case 'm': case 'M':
                trackingMode = !trackingMode;
                showMessage(trackingMode ? "Mode: Tracking" : "Mode: Pomodoro");
                break;
            case 'd': case 'D':
                setupWorkMin  = Storage::getWorkMin();
                setupShortMin = Storage::getShortMin();
                setupLongMin  = Storage::getLongMin();
                appState = ST_SETUP_WORK_MIN; break;
            case 'h': case 'H':
                prevState = appState;
                appState  = ST_HELP; break;
            case 'w': case 'W':
                sessionLogScroll = 0;
                appState = ST_SESSION_LOG; break;
            case 'o': case 'O':
                isEditingSettings = true;
                startWifiScan();
                break;
            case 'x': case 'X':
                if (taskCount > 0 && selectedTask < taskCount)
                    appState = ST_TASK_ACTION;
                break;
            default: break;
        }
    }
    if (ks.enter && taskCount > 0 && selectedTask < taskCount)
        startTimer(selectedTask);
}

// ── Category list ──────────────────────────────────────────────────────────────
static void onKeyCategoryList(Keyboard_Class::KeysState& ks) {
    if (ks.fn) { appState = ST_TASK_LIST; return; }

    for (char c : ks.word) {
        if (c == '.') {
            if (selectedCat < catCount - 1) selectedCat++;
        } else if (c == ';') {
            if (selectedCat > 0) selectedCat--;
        } else if (c == 'n' || c == 'N') {
            inputCatName[0] = '\0';
            inputCatColorIdx = 0;
            appState = ST_NEW_CATEGORY_NAME;
            return;
        } else if (c == 'd' || c == 'D') {
            if (catCount > 0 && selectedCat < catCount) {
                // Remove from local list — push deletion is handled by soft-delete on server
                // (for simplicity, just remove locally and mark as needing a push)
                // Shift left
                for (int i = selectedCat; i < catCount - 1; i++)
                    categories[i] = categories[i + 1];
                catCount--;
                if (selectedCat >= catCount && catCount > 0) selectedCat = catCount - 1;
                Storage::saveCategories(categories, catCount);
                showMessage("Category deleted");
                return;
            }
        }
    }
}

// ── New category — name ────────────────────────────────────────────────────────
static void onKeyNewCategoryName(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) appendChar(inputCatName, sizeof(inputCatName), c);
    if (ks.del) backspace(inputCatName);
    if (ks.fn)  { appState = ST_CATEGORY_LIST; return; }
    if (ks.enter && strlen(inputCatName) > 0) appState = ST_NEW_CATEGORY_COLOR;
}

// ── New category — colour picker ───────────────────────────────────────────────
static void onKeyNewCategoryColor(Keyboard_Class::KeysState& ks) {
    if (ks.fn) { appState = ST_NEW_CATEGORY_NAME; return; }

    for (char c : ks.word) {
        if (c == '.' && inputCatColorIdx < CAT_COLOR_COUNT - 1) inputCatColorIdx++;
        if (c == ';' && inputCatColorIdx > 0)                   inputCatColorIdx--;
    }

    if (ks.enter) {
        if (catCount < MAX_CATEGORIES) {
            Category& cat = categories[catCount];
            generateUUID(cat.id);
            cat.server_id = 0;
            strlcpy(cat.name,  inputCatName,            sizeof(cat.name));
            strlcpy(cat.color, kCatColors[inputCatColorIdx], sizeof(cat.color));
            cat.needs_push = true;

            if (strlen(jwtToken) > 0)
                Api::pushCategory(jwtToken, cat);
            catCount++;
            Storage::saveCategories(categories, catCount);
        }
        appState = ST_CATEGORY_LIST;
        showMessage("Category created!");
    }
}

// ── New task — type ────────────────────────────────────────────────────────────
static void onKeyNewTaskType(Keyboard_Class::KeysState& ks) {
    if (ks.fn) { appState = ST_TASK_LIST; return; }

    for (char c : ks.word) {
        if (c == '.' || c == ';') inputTaskIsTracker = !inputTaskIsTracker;
    }

    if (ks.enter) {
        inputTaskName[0] = '\0';
        inputTaskGoal    = 4;
        appState = ST_NEW_TASK_NAME;
    }
}

// ── New task — name ────────────────────────────────────────────────────────────
static void onKeyNewTaskName(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) appendChar(inputTaskName, sizeof(inputTaskName), c);
    if (ks.del) backspace(inputTaskName);
    if (ks.fn)  { appState = ST_NEW_TASK_TYPE; return; }
    if (ks.enter && strlen(inputTaskName) > 0) {
        if (inputTaskIsTracker) {
            // Tracker tasks skip goal step, go straight to category
            inputTaskCatIdx = 0;
            appState = ST_NEW_TASK_CATEGORY;
        } else {
            appState = ST_NEW_TASK_GOAL;
        }
    }
}

// ── New task — goal ────────────────────────────────────────────────────────────
static void onKeyNewTaskGoal(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) {
        if (c == '+' && inputTaskGoal < 12) inputTaskGoal++;
        if (c == '-' && inputTaskGoal >  1) inputTaskGoal--;
    }
    if (ks.fn) { appState = ST_NEW_TASK_NAME; return; }
    if (ks.enter) {
        inputTaskCatIdx = 0;
        appState = ST_NEW_TASK_CATEGORY;
    }
}

// ── New task — category ────────────────────────────────────────────────────────
static void onKeyNewTaskCategory(Keyboard_Class::KeysState& ks) {
    const int total = catCount + 1;  // item 0 = none, 1..catCount = category
    if (ks.fn) { appState = inputTaskIsTracker ? ST_NEW_TASK_NAME : ST_NEW_TASK_GOAL; return; }

    for (char c : ks.word) {
        if (c == '.' && inputTaskCatIdx < total - 1) inputTaskCatIdx++;
        if (c == ';' && inputTaskCatIdx > 0)         inputTaskCatIdx--;
    }

    if (ks.enter) {
        if (taskCount < MAX_TASKS) {
            Task& t       = tasks[taskCount];
            generateUUID(t.id);
            t.server_id   = 0;
            strlcpy(t.title, inputTaskName, sizeof(t.title));
            t.is_tracker     = inputTaskIsTracker;
            t.pomodoro_goal  = inputTaskIsTracker ? 0 : inputTaskGoal;
            t.pomodoros_done = 0;
            t.is_completed   = false;
            t.created_at     = nowMs();
            t.updated_at     = t.created_at;
            t.needs_push     = true;

            // Assign category
            if (inputTaskCatIdx > 0 && inputTaskCatIdx - 1 < catCount)
                strlcpy(t.category_id, categories[inputTaskCatIdx - 1].id, sizeof(t.category_id));
            else
                t.category_id[0] = '\0';

            bool pushed = false;
            if (strlen(jwtToken) > 0)
                pushed = Api::pushTask(jwtToken, tasks[taskCount]);

            selectedTask = taskCount;
            taskCount++;
            Storage::saveTasks(tasks, taskCount);

            appState = ST_TASK_LIST;
            if (strlen(jwtToken) > 0 && !pushed)
                showMessage("Task saved (sync failed!)");
            else
                showMessage(inputTaskIsTracker ? "Tracker task created!" : "Pomodoro task created!");
        } else {
            appState = ST_TASK_LIST;
        }
    }
}

static void onKeyLoginEmail(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) {
        if (c == 'r' || c == 'R') {
            inputEmail[0] = '\0'; inputPass[0] = '\0';
            appState = ST_REGISTER_EMAIL;
            return;
        }
        appendChar(inputEmail, sizeof(inputEmail), c);
    }
    if (ks.del)  backspace(inputEmail);
    if (ks.fn)   { appState = ST_TASK_LIST; return; }
    if (ks.enter && strlen(inputEmail) > 0) appState = ST_LOGIN_PASS;
}

static void onKeyRegisterEmail(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) appendChar(inputEmail, sizeof(inputEmail), c);
    if (ks.del) backspace(inputEmail);
    if (ks.fn)  { appState = ST_TASK_LIST; return; }
    if (ks.enter && strlen(inputEmail) > 0) {
        inputPass[0] = '\0';
        appState = ST_REGISTER_PASS;
    }
}

static void onKeyRegisterPass(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) appendChar(inputPass, sizeof(inputPass), c);
    if (ks.del) backspace(inputPass);
    if (ks.fn)  { appState = ST_REGISTER_EMAIL; return; }

    if (ks.enter) {
        if (strlen(inputPass) < 8) { showMessage("Password: min 8 chars!"); return; }
        showMessage("Creating account...", 30000);
        char err[64];
        bool ok = Api::registerUser(inputEmail, inputPass, jwtToken, sizeof(jwtToken),
                                    err, sizeof(err));
        if (ok) {
            Storage::saveAuth(jwtToken, inputEmail);
            strlcpy(userEmail, inputEmail, sizeof(userEmail));
            doSync();
            appState = ST_TASK_LIST;
            showMessage("Account created!");
        } else {
            appState = ST_TASK_LIST;
            showMessage(err);
        }
    }
}

static void onKeyLoginPass(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) appendChar(inputPass, sizeof(inputPass), c);
    if (ks.del) backspace(inputPass);
    if (ks.fn)  { appState = ST_LOGIN_EMAIL; return; }

    if (ks.enter && strlen(inputPass) > 0) {
        showMessage("Logging in...", 60000);
        char err[64];
        bool ok = Api::login(inputEmail, inputPass, jwtToken, sizeof(jwtToken),
                             err, sizeof(err));
        if (ok) {
            Storage::saveAuth(jwtToken, inputEmail);
            strlcpy(userEmail, inputEmail, sizeof(userEmail));
            doSync();
            appState = ST_TASK_LIST;
            showMessage("Logged in!");
        } else {
            appState = ST_TASK_LIST;
            showMessage(err);
        }
    }
}

static void onKeyTimer(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) {
        if (c == ' ' || c == 'p' || c == 'P') {
            if (Timer::isRunning())     { Timer::pause();  appState = ST_TIMER_PAUSED;  }
            else if (Timer::isPaused()) { Timer::resume(); appState = ST_TIMER_RUNNING; }
        }
        if (c == 'x' || c == 'X') {
            if (Timer::isCountUp()) completeTrackingSession();
            else                    { Timer::stop(); appState = ST_TASK_LIST; }
        }
    }
    if (ks.enter) {
        if (Timer::isRunning())     { Timer::pause();  appState = ST_TIMER_PAUSED;  }
        else if (Timer::isPaused()) { Timer::resume(); appState = ST_TIMER_RUNNING; }
    }
}

static void onKeyWifiScanList(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) {
        if (c == '.') {
            if (scanSelectedIdx < scanCount - 1) scanSelectedIdx++;
        } else if (c == ';') {
            if (scanSelectedIdx > 0) scanSelectedIdx--;
        } else if (c == 'r' || c == 'R') {
            startWifiScan();
            return;
        } else if (c == 't' || c == 'T') {
            inputSSID[0]  = '\0';
            inputWPass[0] = '\0';
            appState = ST_SETUP_SSID;
            return;
        }
    }
    if (ks.fn) { appState = ST_TASK_LIST; return; }

    if (ks.enter && scanCount > 0 && scanSelectedIdx < scanCount) {
        strlcpy(inputSSID, scanSSIDs[scanSelectedIdx], sizeof(inputSSID));
        inputWPass[0] = '\0';
        for (int i = 0; i < autoConnectCount; i++) {
            if (strcmp(knownNets[i].ssid, inputSSID) == 0) {
                strlcpy(inputWPass, knownNets[i].pass, sizeof(inputWPass));
                break;
            }
        }
        appState = ST_SETUP_PASS;
    }
}

static void onKeyTaskAction(Keyboard_Class::KeysState& ks) {
    if (ks.fn) { appState = ST_TASK_LIST; return; }

    for (char c : ks.word) {
        if (c == 'd' || c == 'D') {
            tasks[selectedTask].is_completed = true;
            tasks[selectedTask].needs_push   = true;
            if (strlen(jwtToken) > 0)
                Api::pushTask(jwtToken, tasks[selectedTask]);
            Storage::saveTasks(tasks, taskCount);
            appState = ST_TASK_LIST;
            showMessage("Task marked complete");
            return;
        }
        if (c == 'r' || c == 'R') {
            tasks[selectedTask].is_completed = false;
            tasks[selectedTask].needs_push   = true;
            if (strlen(jwtToken) > 0)
                Api::pushTask(jwtToken, tasks[selectedTask]);
            Storage::saveTasks(tasks, taskCount);
            appState = ST_TASK_LIST;
            showMessage("Task restored");
            return;
        }
    }
}

static void onKeySetupSSID(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) appendChar(inputSSID, sizeof(inputSSID), c);
    if (ks.del) backspace(inputSSID);
    if (ks.fn)  { appState = ST_WIFI_SCAN_LIST; return; }
    if (ks.enter && strlen(inputSSID) > 0) appState = ST_SETUP_PASS;
}

static void onKeySetupPass(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) appendChar(inputWPass, sizeof(inputWPass), c);
    if (ks.del) backspace(inputWPass);
    if (ks.fn)  { appState = ST_WIFI_SCAN_LIST; return; }
    if (ks.enter) {
        Storage::addOrUpdateNetwork(inputSSID, inputWPass);
        autoConnectCount = Storage::getNetworks(knownNets, MAX_WIFI_NETS);

        String apiUrl = Storage::getApiUrl();
        if (apiUrl.length() == 0) {
            inputApiUrl[0] = '\0';
            appState = ST_SETUP_API;
        } else {
            Api::init(apiUrl.c_str());
            WifiNet net;
            strlcpy(net.ssid, inputSSID, sizeof(net.ssid));
            strlcpy(net.pass, inputWPass, sizeof(net.pass));
            autoConnectIdx = 0;
            startWifiNet(net);
        }
    }
}

static void onKeySetupApi(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) appendChar(inputApiUrl, sizeof(inputApiUrl), c);
    if (ks.del) backspace(inputApiUrl);
    if (ks.fn)  { appState = ST_SETUP_PASS; return; }

    if (ks.enter && strlen(inputApiUrl) > 0) {
        Storage::saveApiUrl(inputApiUrl);
        Api::init(inputApiUrl);
        showMessage("Settings saved!");

        if (strlen(inputSSID) > 0) {
            WifiNet net;
            strlcpy(net.ssid, inputSSID, sizeof(net.ssid));
            strlcpy(net.pass, inputWPass, sizeof(net.pass));
            autoConnectIdx = 0;
            startWifiNet(net);
        } else {
            startWifiScan();
        }
    }
}

static void onKeySetupWorkMin(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) {
        if (c == '+' && setupWorkMin < 90) setupWorkMin++;
        if (c == '-' && setupWorkMin >  1) setupWorkMin--;
    }
    if (ks.fn)    { appState = ST_TASK_LIST; return; }
    if (ks.enter) appState = ST_SETUP_SHORT_MIN;
}

static void onKeySetupShortMin(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) {
        if (c == '+' && setupShortMin < 30) setupShortMin++;
        if (c == '-' && setupShortMin >  1) setupShortMin--;
    }
    if (ks.fn)    { appState = ST_SETUP_WORK_MIN; return; }
    if (ks.enter) appState = ST_SETUP_LONG_MIN;
}

static void onKeySetupLongMin(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) {
        if (c == '+' && setupLongMin < 60) setupLongMin++;
        if (c == '-' && setupLongMin >  1) setupLongMin--;
    }
    if (ks.fn) { appState = ST_SETUP_SHORT_MIN; return; }

    if (ks.enter) {
        Storage::saveDurations(setupWorkMin, setupShortMin, setupLongMin);
        appState = ST_TASK_LIST;
        showMessage("Durations saved!");
    }
}

// ─── Setup ────────────────────────────────────────────────────────────────────
void setup() {
    auto cfg = M5.config();
    M5Cardputer.begin(cfg, true);
    M5Cardputer.Display.setRotation(1);
    M5Cardputer.Display.setBrightness(128);
    M5Cardputer.Speaker.begin();
    M5Cardputer.Speaker.setVolume(200);
    beepEnabled = Storage::getBeep();

    UI::init();
    Storage::init();

    // Restore locally-persisted categories and tasks
    catCount  = Storage::loadCategories(categories, MAX_CATEGORIES);
    taskCount = Storage::loadTasks(tasks, MAX_TASKS);

    // Restore auth
    String tok = Storage::getToken();
    String em  = Storage::getEmail();
    if (tok.length() > 0) {
        strlcpy(jwtToken,  tok.c_str(), sizeof(jwtToken));
        strlcpy(userEmail, em.c_str(),  sizeof(userEmail));
    }

    // Init API client
    String apiUrl = Storage::getApiUrl();
    Api::init(apiUrl.c_str());

    // Import launcher networks if none saved
    if (Storage::getNetworkCount() == 0)
        Storage::importLauncherNetworks();

    autoConnectCount = Storage::getNetworks(knownNets, MAX_WIFI_NETS);

    if (autoConnectCount > 0) {
        autoConnectIdx = 0;
        startWifiNet(knownNets[0]);
    } else if (apiUrl.length() == 0) {
        inputSSID[0] = '\0'; inputWPass[0] = '\0'; inputApiUrl[0] = '\0';
        isEditingSettings = false;
        appState = ST_SETUP_API;
    } else {
        startWifiScan();
    }
}

// ─── Loop ─────────────────────────────────────────────────────────────────────
void loop() {
    M5Cardputer.update();
    unsigned long now = millis();

    if (now - lastCursorToggle > 500) {
        cursorVisible    = !cursorVisible;
        lastCursorToggle = now;
    }

    // ── WiFi connecting ──
    if (appState == ST_WIFI_CONNECTING) {
        if (now - lastWifiDotMs > 400) {
            wifiDots = (wifiDots + 1) % 4;
            lastWifiDotMs = now;
            UI::drawWifiConnecting(wifiSSID, wifiDots);
        }
        if (WiFi.status() == WL_CONNECTED) {
            configTime(0, 0, "pool.ntp.org", "time.google.com");
            if (strlen(jwtToken) > 0) {
                pullFromServer();
                Storage::saveCategories(categories, catCount);
                Storage::saveTasks(tasks, taskCount);
            }
            appState = ST_TASK_LIST;
        } else if (now - wifiStartMs > 15000) {
            autoConnectIdx++;
            if (autoConnectIdx < autoConnectCount) {
                startWifiNet(knownNets[autoConnectIdx]);
            } else {
                if (scanCount > 0) {
                    WiFi.disconnect(false);
                    scanSelectedIdx = 0;
                    appState = ST_WIFI_SCAN_LIST;
                } else {
                    startWifiScan();
                }
            }
        }
        return;
    }

    // ── WiFi scanning (async) ──
    if (appState == ST_WIFI_SCAN) {
        if (now - lastWifiDotMs > 400) {
            wifiDots = (wifiDots + 1) % 4;
            lastWifiDotMs = now;
            UI::drawWifiScanning(wifiDots);
        }

        int n = WiFi.scanComplete();
        if (n >= 0) {
            scanCount = min(n, MAX_SCAN_NETS);
            for (int i = 0; i < scanCount; i++) {
                strlcpy(scanSSIDs[i], WiFi.SSID(i).c_str(), sizeof(scanSSIDs[i]));
                scanRSSI[i]     = WiFi.RSSI(i);
                scanSSIDPtrs[i] = scanSSIDs[i];
            }
            WiFi.scanDelete();
            scanSelectedIdx = 0;
            appState = ST_WIFI_SCAN_LIST;
        } else if (n == WIFI_SCAN_FAILED) {
            scanCount       = 0;
            scanSelectedIdx = 0;
            appState        = ST_WIFI_SCAN_LIST;
        }

        if (M5Cardputer.Keyboard.isChange() && M5Cardputer.Keyboard.isPressed()) {
            Keyboard_Class::KeysState ks = M5Cardputer.Keyboard.keysState();
            if (ks.fn) {
                WiFi.scanDelete();
                scanSelectedIdx = 0;
                appState        = ST_WIFI_SCAN_LIST;
            }
        }
        return;
    }

    // ── Timed message ──
    if (appState == ST_MESSAGE) {
        if (now >= messageUntilMs) appState = prevState;
        return;
    }

    // ── Pomodoro completion ──
    if (!Timer::isCountUp()
        && (appState == ST_TIMER_RUNNING || appState == ST_TIMER_PAUSED)
        && Timer::isComplete()) {
        completeTimer();
    }

    // ── Keyboard input ──
    if (M5Cardputer.Keyboard.isChange() && M5Cardputer.Keyboard.isPressed()) {
        Keyboard_Class::KeysState ks = M5Cardputer.Keyboard.keysState();

        bool inTextInput = (appState == ST_LOGIN_EMAIL        || appState == ST_LOGIN_PASS        ||
                            appState == ST_REGISTER_EMAIL      || appState == ST_REGISTER_PASS     ||
                            appState == ST_NEW_TASK_NAME       || appState == ST_NEW_CATEGORY_NAME ||
                            appState == ST_SETUP_SSID          || appState == ST_SETUP_PASS        ||
                            appState == ST_SETUP_API);
        if (!inTextInput) {
            for (char c : ks.word) {
                if (c == 'b' || c == 'B') {
                    displayOn = !displayOn;
                    M5Cardputer.Display.setBrightness(displayOn ? BRIGHTNESS_ON : 0);
                }
                if (c == 'a' || c == 'A') {
                    beepEnabled = !beepEnabled;
                    Storage::saveBeep(beepEnabled);
                    showMessage(beepEnabled ? "Beep: ON" : "Beep: OFF");
                }
                (void)c; // '?' unused
            }
        }

        switch (appState) {
            case ST_TASK_LIST:          onKeyTaskList(ks);          break;
            case ST_CATEGORY_LIST:      onKeyCategoryList(ks);      break;
            case ST_NEW_CATEGORY_NAME:  onKeyNewCategoryName(ks);   break;
            case ST_NEW_CATEGORY_COLOR: onKeyNewCategoryColor(ks);  break;
            case ST_NEW_TASK_TYPE:      onKeyNewTaskType(ks);       break;
            case ST_NEW_TASK_NAME:      onKeyNewTaskName(ks);       break;
            case ST_NEW_TASK_GOAL:      onKeyNewTaskGoal(ks);       break;
            case ST_NEW_TASK_CATEGORY:  onKeyNewTaskCategory(ks);   break;
            case ST_LOGIN_EMAIL:        onKeyLoginEmail(ks);        break;
            case ST_LOGIN_PASS:         onKeyLoginPass(ks);         break;
            case ST_TIMER_RUNNING:
            case ST_TIMER_PAUSED:       onKeyTimer(ks);             break;
            case ST_WIFI_SCAN_LIST:     onKeyWifiScanList(ks);      break;
            case ST_SESSION_LOG:
                for (char c : ks.word) {
                    if (c == '.' && sessionLogScroll < sessionLogCount - 1) sessionLogScroll++;
                    if (c == ';' && sessionLogScroll > 0) sessionLogScroll--;
                    if (c == 'r' || c == 'R') {
                        if (strlen(jwtToken) == 0) { showMessage("Not logged in"); break; }
                        if (WiFi.status() != WL_CONNECTED) { showMessage("Not connected"); break; }
                        showMessage("Loading sessions...", 10000);
                        bool ok = pullFromServer(true);
                        if (!ok) showMessage("Refresh failed — retry");
                        else {
                            char buf[28];
                            snprintf(buf, sizeof(buf), "%d sessions loaded", sessionLogCount);
                            showMessage(buf);
                        }
                    }
                }
                if (ks.fn) appState = ST_TASK_LIST;
                break;
            case ST_TASK_ACTION:        onKeyTaskAction(ks);        break;
            case ST_REGISTER_EMAIL:     onKeyRegisterEmail(ks);     break;
            case ST_REGISTER_PASS:      onKeyRegisterPass(ks);      break;
            case ST_HELP:
                if (ks.fn) appState = prevState;
                break;
            case ST_SETUP_SSID:         onKeySetupSSID(ks);         break;
            case ST_SETUP_PASS:         onKeySetupPass(ks);         break;
            case ST_SETUP_API:          onKeySetupApi(ks);          break;
            case ST_SETUP_WORK_MIN:     onKeySetupWorkMin(ks);      break;
            case ST_SETUP_SHORT_MIN:    onKeySetupShortMin(ks);     break;
            case ST_SETUP_LONG_MIN:     onKeySetupLongMin(ks);      break;
            default:                    break;
        }
    }

    // ── Render ──
    switch (appState) {
        case ST_TASK_LIST:
        case ST_SYNCING:
            UI::drawTaskList(tasks, taskCount, selectedTask,
                             appState == ST_SYNCING, userEmail, trackingMode,
                             categories, catCount);
            break;

        case ST_CATEGORY_LIST:
            UI::drawCategoryList(categories, catCount, selectedCat);
            break;

        case ST_NEW_CATEGORY_NAME:
            UI::drawNewCategoryName(inputCatName, cursorVisible);
            break;

        case ST_NEW_CATEGORY_COLOR:
            UI::drawCategoryColorPicker(inputCatName, inputCatColorIdx);
            break;

        case ST_NEW_TASK_TYPE:
            UI::drawNewTaskType(inputTaskIsTracker);
            break;

        case ST_NEW_TASK_NAME:
            UI::drawNewTaskName(inputTaskName, cursorVisible);
            break;

        case ST_NEW_TASK_GOAL:
            UI::drawNewTaskGoal(inputTaskName, inputTaskGoal);
            break;

        case ST_NEW_TASK_CATEGORY:
            UI::drawNewTaskCategory(categories, catCount, inputTaskCatIdx);
            break;

        case ST_TIMER_RUNNING:
        case ST_TIMER_PAUSED: {
            const char* tname = (activeTaskIdx >= 0 && activeTaskIdx < taskCount)
                                ? tasks[activeTaskIdx].title : "";
            bool countUp = Timer::isCountUp();
            int  secs    = countUp ? Timer::elapsedSeconds() : Timer::remainingSeconds();
            UI::drawTimer(Timer::currentPhase, secs, sessionDurationSec,
                          tname, Timer::completedPomodoros, Timer::isPaused(), countUp);
            break;
        }

        case ST_LOGIN_EMAIL:
            UI::drawLoginEmail(inputEmail, cursorVisible); break;

        case ST_LOGIN_PASS:
            UI::drawLoginPass(inputEmail, inputPass, cursorVisible); break;

        case ST_REGISTER_EMAIL:
            UI::drawRegisterEmail(inputEmail, cursorVisible); break;

        case ST_REGISTER_PASS:
            UI::drawRegisterPass(inputEmail, inputPass, cursorVisible); break;

        case ST_WIFI_SCAN_LIST:
            UI::drawWifiScanList(scanSSIDPtrs, scanRSSI, scanCount, scanSelectedIdx);
            break;

        case ST_SESSION_LOG:
            UI::drawSessionLog(sessionLog, sessionLogCount, sessionLogScroll);
            break;

        case ST_SETUP_SSID:
            UI::drawSetupSSID(inputSSID, cursorVisible, isEditingSettings); break;

        case ST_SETUP_PASS:
            UI::drawSetupPass(inputSSID, inputWPass, cursorVisible, isEditingSettings); break;

        case ST_SETUP_API:
            UI::drawSetupApi(inputApiUrl, cursorVisible, isEditingSettings); break;

        case ST_TASK_ACTION:
            UI::drawTaskAction(tasks[selectedTask]); break;

        case ST_HELP:
            UI::drawHelp(); break;

        case ST_SETUP_WORK_MIN:
            UI::drawDurationScreen("Work", setupWorkMin, 1); break;

        case ST_SETUP_SHORT_MIN:
            UI::drawDurationScreen("Short Break", setupShortMin, 2); break;

        case ST_SETUP_LONG_MIN:
            UI::drawDurationScreen("Long Break", setupLongMin, 3); break;

        default: break;
    }

    delay(50);  // ~20 FPS
}
