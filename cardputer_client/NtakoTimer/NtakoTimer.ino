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
 *  ▼  next task    ▲  prev task   ENTER  start timer
 *  N      new task (name → category)
 *  M      categorie (▼▶▲ nav  N new  D delete  ENTER filter)
 *  C      impostazioni (allarme / break)
 *  S      sync                    L      login
 *  O      WiFi scan / add network
 *  H      keybinding help         W      session log
 *  A      beep on/off             B      display on/off
 *  (timer)    SPC/ENTER pause     X      stop + salva
 *  (scan)     ▼▶▲ nav  ENTER pick  T manual SSID  R rescan
 *  (categorie) N nuova  D elimina  ENTER filtro task  ESC annulla
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

// ── Input buffers — auth ──────────────────────────────────────────────────────
static char  inputEmail[64]               = "";
static char  inputPass[64]                = "";

// ── Input buffers — new task ──────────────────────────────────────────────────
static char  inputTaskName[MAX_TITLE_LEN] = "";
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

// ── Active session ────────────────────────────────────────────────────────────
static char    activeSessionId[37] = "";
static int     activeTaskIdx       = -1;
static int64_t sessionStartedAt    = 0;

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

// ── Alarm & break ─────────────────────────────────────────────────────────────
static int           lastAlarmMinute   = 0;    // last minute that triggered alarm
static int           pauseCountdownSec = 0;    // break countdown
static unsigned long lastBreakTickMs   = 0;
static int           pauseNagSec       = 0;    // nag countdown after break ends
static unsigned long lastNagTickMs     = 0;

// ── Setup buffers — alarm/break/volume ────────────────────────────────────────
static int   setupAlarmMin = 120;
static int   setupBreakMin = 15;
static int   setupVolume   = 8;

// ── Task editing ──────────────────────────────────────────────────────────────
static int   editTaskCatIdx = 0;   // category picker for existing task
static int   helpPage       = 0;   // help screen page (0 or 1)

// ── Task totals & session summaries ───────────────────────────────────────────
static int         taskTotalSec[MAX_TASKS];
static TaskSummary sessionSummaries[MAX_TASKS];
static int         summaryCount = 0;

// Sort tasks[] in place by (hasCategory desc, catName asc, title asc).
// Also adjusts selectedTask so it still points to the same task.
static void sortTasksByCategory() {
    if (taskCount < 2) return;
    char selId[37] = "";
    if (selectedTask >= 0 && selectedTask < taskCount)
        strlcpy(selId, tasks[selectedTask].id, sizeof(selId));

    for (int i = 1; i < taskCount; i++) {
        Task tmp = tasks[i];
        bool tmpHas = (tmp.category_id[0] != '\0');
        const char* tmpCat = "";
        if (tmpHas) for (int c = 0; c < catCount; c++)
            if (strcmp(categories[c].id, tmp.category_id) == 0) { tmpCat = categories[c].name; break; }

        int j = i - 1;
        while (j >= 0) {
            bool jHas = (tasks[j].category_id[0] != '\0');
            const char* jCat = "";
            if (jHas) for (int c = 0; c < catCount; c++)
                if (strcmp(categories[c].id, tasks[j].category_id) == 0) { jCat = categories[c].name; break; }

            int cmp = tmpHas == jHas ? strcmp(tmpCat, jCat)
                    : (tmpHas ? -1 : 1);
            if (cmp == 0) cmp = strcmp(tmp.title, tasks[j].title);
            if (cmp >= 0) break;
            tasks[j + 1] = tasks[j];
            j--;
        }
        tasks[j + 1] = tmp;
    }

    if (selId[0] != '\0')
        for (int i = 0; i < taskCount; i++)
            if (strcmp(tasks[i].id, selId) == 0) { selectedTask = i; break; }
}

// Fill out[i] with total tracked seconds for tasks[i] from the session log.
static void computeTaskTotals(int* out) {
    for (int i = 0; i < taskCount; i++) {
        out[i] = 0;
        if (tasks[i].id[0] == '\0') continue;
        for (int s = 0; s < sessionLogCount; s++)
            if (strcmp(sessionLog[s].taskId, tasks[i].id) == 0)
                out[i] += sessionLog[s].durationSec;
    }
}

// Build aggregated per-task summaries (tasks sorted by category, with sessions only).
static void buildSummaries(TaskSummary* out, int& count) {
    count = 0;
    for (int i = 0; i < taskCount && count < MAX_TASKS; i++) {
        int total = 0;
        if (tasks[i].id[0] != '\0')
            for (int s = 0; s < sessionLogCount; s++)
                if (strcmp(sessionLog[s].taskId, tasks[i].id) == 0)
                    total += sessionLog[s].durationSec;
        if (total == 0) continue;

        TaskSummary& sm = out[count++];
        strlcpy(sm.name, tasks[i].title, sizeof(sm.name));
        sm.totalSec    = total;
        sm.catColor[0] = '\0';
        for (int c = 0; c < catCount; c++)
            if (strcmp(categories[c].id, tasks[i].category_id) == 0) {
                strlcpy(sm.catColor, categories[c].color, sizeof(sm.catColor));
                break;
            }
    }
}

static void pushSessionLog(const char* clientId, const char* taskId,
                           const char* taskName, int durationSec,
                           int64_t startedAt, int64_t endedAt, bool needs_push) {
    int n = min(sessionLogCount, MAX_SESSION_LOG - 1);
    for (int i = n; i > 0; i--) sessionLog[i] = sessionLog[i - 1];
    strlcpy(sessionLog[0].clientId,  clientId,  sizeof(sessionLog[0].clientId));
    strlcpy(sessionLog[0].taskId,    taskId,    sizeof(sessionLog[0].taskId));
    strlcpy(sessionLog[0].taskName,  taskName,  sizeof(sessionLog[0].taskName));
    sessionLog[0].durationSec = durationSec;
    sessionLog[0].startedAt   = startedAt;
    sessionLog[0].endedAt     = endedAt;
    sessionLog[0].needs_push  = needs_push;
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
static char         _pullErr[52] = "";  // why the last pull failed, for the message

static bool pullFromServer(bool /*forceFull*/ = false) {
    if (strlen(jwtToken) == 0) return false;

    int64_t since      = 0;
    int64_t serverTime = 0;
    int     inCatCount = 0;
    int     sesCount   = 0;

    _pullErr[0] = '\0';
    int n = Api::pull(jwtToken, since,
                      _incomingCats, MAX_CATEGORIES, inCatCount,
                      _incoming, MAX_TASKS, serverTime,
                      _incomingSessions, MAX_SESSION_LOG, &sesCount,
                      _pullErr, sizeof(_pullErr));
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
            sessionLog[sessionLogCount] = _incomingSessions[i]; // copies all fields, needs_push=false
            SessionEntry& se = sessionLog[sessionLogCount];
            // Resolve taskId to title
            bool resolved = false;
            for (int j = 0; j < taskCount; j++) {
                if (strcmp(tasks[j].id, se.taskId) == 0) {
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
    sortTasksByCategory();
    return true;
}

static void doSync() {
    if (strlen(jwtToken) == 0) { showMessage("Not logged in"); return; }

    // Connect WiFi on demand if not already connected
    if (WiFi.status() != WL_CONNECTED) {
        // Scan first to see which known networks are actually in range
        showMessage("Scansione WiFi...", 30000);
        WiFi.mode(WIFI_STA);
        int found = WiFi.scanNetworks(); // blocking

        // Populate scan list (for manual fallback)
        scanCount = min(found, MAX_SCAN_NETS);
        for (int i = 0; i < scanCount; i++) {
            strlcpy(scanSSIDs[i], WiFi.SSID(i).c_str(), sizeof(scanSSIDs[i]));
            scanRSSI[i]     = WiFi.RSSI(i);
            scanSSIDPtrs[i] = scanSSIDs[i];
        }

        // Find first saved network visible in scan results
        int matchNet = -1;
        for (int s = 0; s < found && matchNet < 0; s++) {
            String ssid = WiFi.SSID(s);
            for (int n = 0; n < autoConnectCount; n++) {
                if (ssid == knownNets[n].ssid) { matchNet = n; break; }
            }
        }
        WiFi.scanDelete();

        if (matchNet < 0) {
            // No known network in range → let user pick manually
            scanSelectedIdx = 0;
            showMessage("Nessuna rete nota in range");
            appState = ST_WIFI_SCAN_LIST;
            return;
        }

        // Connect to matched network
        showMessage("Connessione WiFi...", 30000);
        WiFi.begin(knownNets[matchNet].ssid, knownNets[matchNet].pass);
        unsigned long t0 = millis();
        while (WiFi.status() != WL_CONNECTED && millis() - t0 < 10000)
            delay(200);
        if (WiFi.status() != WL_CONNECTED) { showMessage("WiFi failed — retry"); return; }
        configTime(0, 0, "pool.ntp.org", "time.google.com");
    }

    AppState saved = appState;
    appState = ST_SYNCING;
    computeTaskTotals(taskTotalSec);
    UI::drawTaskList(tasks, taskCount, selectedTask, true, userEmail,
                     categories, catCount, taskTotalSec);

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

    // 3. Push pending sessions (survived reboot, not yet synced)
    int sessPushOk = 0;
    for (int i = 0; i < sessionLogCount; i++) {
        if (!sessionLog[i].needs_push) continue;
        if (sessionLog[i].durationSec <= 0) { sessionLog[i].needs_push = false; continue; }
        bool ok = Api::pushSession(jwtToken, sessionLog[i].clientId,
                                   sessionLog[i].taskId, "tracking",
                                   sessionLog[i].startedAt, sessionLog[i].endedAt,
                                   sessionLog[i].durationSec);
        if (ok) { sessionLog[i].needs_push = false; sessPushOk++; }
    }
    if (sessPushOk > 0) Storage::saveSessionLog(sessionLog, sessionLogCount);

    // 4. Pull and merge server state
    bool pulled = pullFromServer();

    // 5. Persist locally
    Storage::saveCategories(categories, catCount);
    Storage::saveTasks(tasks, taskCount);
    Storage::saveSessionLog(sessionLog, sessionLogCount);

    appState = saved;

    char msg[64];
    if (pushFail > 0 && firstErr[0] != '\0')
        snprintf(msg, sizeof(msg), "Err: %.58s", firstErr);
    else if (pushFail > 0)
        snprintf(msg, sizeof(msg), "Sync: %d ok, %d failed!", pushOk, pushFail);
    else if (!pulled && _pullErr[0] != '\0')
        snprintf(msg, sizeof(msg), "Pull: %.56s", _pullErr);
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
static void startTimer(int taskIdx) {
    activeTaskIdx    = taskIdx;
    sessionStartedAt = nowMs();
    generateUUID(activeSessionId);
    lastAlarmMinute   = 0;
    pauseCountdownSec = 0;
    pauseNagSec       = 0;
    Timer::startCountUp();
    appState = ST_TIMER_RUNNING;

    // Tell the other clients a timer is running here. Only when already
    // online and with real time (NTP): the stop pushes the session anyway.
    if (WiFi.status() == WL_CONNECTED && strlen(jwtToken) > 0
        && sessionStartedAt > 946684800000LL /* 2000-01-01 */) {
        bool hasTask = taskIdx >= 0 && taskIdx < taskCount;
        // The session must find its task on the server: an unsynced task
        // would leave it without one for good.
        if (hasTask && tasks[taskIdx].needs_push)
            Api::pushTask(jwtToken, tasks[taskIdx]);
        Api::pushSession(jwtToken, activeSessionId, hasTask ? tasks[taskIdx].id : "",
                         "tracking", sessionStartedAt, 0, 0);
    }
}

static void beepDone() {
    if (!beepEnabled) return;
    M5Cardputer.Speaker.tone(880,  150); delay(200);
    M5Cardputer.Speaker.tone(880,  150); delay(200);
    M5Cardputer.Speaker.tone(1320, 350); delay(400);
}

static void beepAlarm() {
    if (!beepEnabled) return;
    M5Cardputer.Speaker.tone(1047, 200); delay(250);
    M5Cardputer.Speaker.tone(1047, 200); delay(250);
}

static void beepBreakEnd() {
    if (!beepEnabled) return;
    M5Cardputer.Speaker.tone(523,  150); delay(200);
    M5Cardputer.Speaker.tone(659,  150); delay(200);
    M5Cardputer.Speaker.tone(784,  300); delay(350);
}

static void completeSession() {
    int elapsed     = Timer::elapsedSeconds();
    int64_t endedAt = nowMs();

    // 1. Persist session immediately (needs_push=true) so a watchdog reboot
    //    or any crash during the API call cannot lose the data.
    bool savedLocally = false;
    if (elapsed > 0) {
        bool validIdx = (activeTaskIdx >= 0 && activeTaskIdx < taskCount);
        const char* taskName = validIdx ? tasks[activeTaskIdx].title : "—";
        const char* taskId   = validIdx ? tasks[activeTaskIdx].id   : "";
        pushSessionLog(activeSessionId, taskId, taskName, elapsed,
                       sessionStartedAt, endedAt, /*needs_push=*/true);
        savedLocally = Storage::saveSessionLog(sessionLog, sessionLogCount);
    }

    // 2. Try to push to server; if successful, clear needs_push and resave.
    bool syncOk = false;
    if (elapsed > 0 && strlen(jwtToken) > 0
        && activeTaskIdx >= 0 && activeTaskIdx < taskCount) {
        if (tasks[activeTaskIdx].needs_push)
            Api::pushTask(jwtToken, tasks[activeTaskIdx]);
        syncOk = Api::pushSession(jwtToken, activeSessionId,
                                  tasks[activeTaskIdx].id, "tracking",
                                  sessionStartedAt, endedAt, elapsed);
        if (syncOk && sessionLogCount > 0) {
            sessionLog[0].needs_push = false;
            Storage::saveSessionLog(sessionLog, sessionLogCount);
        }
    }

    beepDone();
    Timer::stop();
    appState = ST_TASK_LIST;

    char msg[48];
    int mm = elapsed / 60, ss = elapsed % 60;
    if (elapsed <= 0) {
        snprintf(msg, sizeof(msg), "Sessione < 1s, scartata");
    } else if (syncOk) {
        snprintf(msg, sizeof(msg), "Tracked %02d:%02d — sync OK", mm, ss);
    } else if (savedLocally) {
        snprintf(msg, sizeof(msg), "Tracked %02d:%02d — salvato offline", mm, ss);
    } else {
        snprintf(msg, sizeof(msg), "Tracked %02d:%02d — ERRORE salvataggio!", mm, ss);
    }
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

// `` ` `` = back / cancel key (replaces Fn)
static bool hasBack(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) if (c == '`') return true;
    return false;
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
                inputTaskName[0] = '\0';
                inputTaskCatIdx  = 0;
                appState = ST_NEW_TASK_NAME;
                break;
            case 'm': case 'M':
                selectedCat = 0;
                appState = ST_CATEGORY_LIST;
                break;
            case 'c': case 'C':
                setupAlarmMin = Storage::getAlarmMin();
                setupBreakMin = Storage::getBreakMin();
                setupVolume   = Storage::getVolume();
                appState = ST_SETUP_ALARM_MIN;
                break;
            case 's': case 'S': doSync(); break;
            case 'l': case 'L':
                inputEmail[0] = '\0'; inputPass[0] = '\0';
                appState = ST_LOGIN_EMAIL; break;
            case 'h': case 'H':
                prevState = appState;
                helpPage  = 0;
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
            case 'i': case 'I':
                if (taskCount > 0 && selectedTask < taskCount)
                    appState = ST_TASK_DETAIL;
                break;
            default: break;
        }
    }
    if (ks.enter && taskCount > 0 && selectedTask < taskCount)
        startTimer(selectedTask);
}

// ── Category list ──────────────────────────────────────────────────────────────
static void onKeyCategoryList(Keyboard_Class::KeysState& ks) {
    if (hasBack(ks)) { appState = ST_TASK_LIST; return; }

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
                for (int i = selectedCat; i < catCount - 1; i++)
                    categories[i] = categories[i + 1];
                catCount--;
                if (selectedCat >= catCount && catCount > 0) selectedCat = catCount - 1;
                Storage::saveCategories(categories, catCount);
                showMessage("Category deleted");
                return;
            }
        } else if (c == 'r' || c == 'R') {
            if (catCount > 0 && selectedCat < catCount) {
                strlcpy(inputCatName, categories[selectedCat].name, sizeof(inputCatName));
                appState = ST_RENAME_CATEGORY;
                return;
            }
        }
    }
}

// ── Rename category ────────────────────────────────────────────────────────────
static void onKeyRenameCategory(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) { if (c == '`') continue; appendChar(inputCatName, sizeof(inputCatName), c); }
    if (ks.del) backspace(inputCatName);
    if (hasBack(ks))  { appState = ST_CATEGORY_LIST; return; }
    if (ks.enter && strlen(inputCatName) > 0) {
        strlcpy(categories[selectedCat].name, inputCatName, sizeof(categories[selectedCat].name));
        categories[selectedCat].needs_push = true;
        if (strlen(jwtToken) > 0)
            Api::pushCategory(jwtToken, categories[selectedCat]);
        Storage::saveCategories(categories, catCount);
        appState = ST_CATEGORY_LIST;
        showMessage("Category renamed!");
    }
}

// ── New category — name ────────────────────────────────────────────────────────
static void onKeyNewCategoryName(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) { if (c == '`') continue; appendChar(inputCatName, sizeof(inputCatName), c); }
    if (ks.del) backspace(inputCatName);
    if (hasBack(ks))  { appState = ST_CATEGORY_LIST; return; }
    if (ks.enter && strlen(inputCatName) > 0) appState = ST_NEW_CATEGORY_COLOR;
}

// ── New category — colour picker ───────────────────────────────────────────────
static void onKeyNewCategoryColor(Keyboard_Class::KeysState& ks) {
    if (hasBack(ks)) { appState = ST_NEW_CATEGORY_NAME; return; }

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

// ── New task — name ────────────────────────────────────────────────────────────
static void onKeyNewTaskName(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) { if (c == '`') continue; appendChar(inputTaskName, sizeof(inputTaskName), c); }
    if (ks.del) backspace(inputTaskName);
    if (hasBack(ks))  { appState = ST_TASK_LIST; return; }
    if (ks.enter && strlen(inputTaskName) > 0) {
        inputTaskCatIdx = 0;
        appState = ST_NEW_TASK_CATEGORY;
    }
}

// ── New task — category ────────────────────────────────────────────────────────
static void onKeyNewTaskCategory(Keyboard_Class::KeysState& ks) {
    const int total = catCount + 1;  // item 0 = none, 1..catCount = category
    if (hasBack(ks)) { appState = ST_NEW_TASK_NAME; return; }

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
            t.is_completed = false;
            t.created_at   = nowMs();
            t.updated_at   = t.created_at;
            t.needs_push   = true;

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
            sortTasksByCategory();

            appState = ST_TASK_LIST;
            if (strlen(jwtToken) > 0 && !pushed)
                showMessage("Task saved (sync failed!)");
            else
                showMessage("Task created!");
        } else {
            appState = ST_TASK_LIST;
        }
    }
}

static void onKeyLoginEmail(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) {
        if (c == '`') continue;
        if (c == 'r' || c == 'R') {
            inputEmail[0] = '\0'; inputPass[0] = '\0';
            appState = ST_REGISTER_EMAIL;
            return;
        }
        appendChar(inputEmail, sizeof(inputEmail), c);
    }
    if (ks.del)  backspace(inputEmail);
    if (hasBack(ks))   { appState = ST_TASK_LIST; return; }
    if (ks.enter && strlen(inputEmail) > 0) appState = ST_LOGIN_PASS;
}

static void onKeyRegisterEmail(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) { if (c == '`') continue; appendChar(inputEmail, sizeof(inputEmail), c); }
    if (ks.del) backspace(inputEmail);
    if (hasBack(ks))  { appState = ST_TASK_LIST; return; }
    if (ks.enter && strlen(inputEmail) > 0) {
        inputPass[0] = '\0';
        appState = ST_REGISTER_PASS;
    }
}

static void onKeyRegisterPass(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) { if (c == '`') continue; appendChar(inputPass, sizeof(inputPass), c); }
    if (ks.del) backspace(inputPass);
    if (hasBack(ks))  { appState = ST_REGISTER_EMAIL; return; }

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
    for (char c : ks.word) { if (c == '`') continue; appendChar(inputPass, sizeof(inputPass), c); }
    if (ks.del) backspace(inputPass);
    if (hasBack(ks))  { appState = ST_LOGIN_EMAIL; return; }

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
            if (Timer::isRunning()) {
                Timer::pause();
                appState = ST_TIMER_PAUSED;
                // Start break countdown
                int brkSec = Storage::getBreakMin() * 60;
                if (brkSec > 0) {
                    pauseCountdownSec = brkSec;
                    lastBreakTickMs   = millis();
                }
            } else if (Timer::isPaused()) {
                Timer::resume();
                appState = ST_TIMER_RUNNING;
                pauseCountdownSec = 0;
                pauseNagSec       = 0;
            }
        }
        if (c == 'x' || c == 'X') {
            pauseCountdownSec = 0;
            pauseNagSec       = 0;
            completeSession();
        }
    }
    if (ks.enter) {
        if (Timer::isRunning()) {
            Timer::pause();
            appState = ST_TIMER_PAUSED;
            // Start break countdown
            int brkSec = Storage::getBreakMin() * 60;
            if (brkSec > 0) {
                pauseCountdownSec = brkSec;
                lastBreakTickMs   = millis();
            }
        } else if (Timer::isPaused()) {
            Timer::resume();
            appState = ST_TIMER_RUNNING;
            pauseCountdownSec = 0;
        }
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
    if (hasBack(ks)) { appState = ST_TASK_LIST; return; }

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
    if (hasBack(ks)) { appState = ST_TASK_LIST; return; }

    for (char c : ks.word) {
        if (c == 'd' || c == 'D') {
            tasks[selectedTask].is_completed = true;
            // Newer than the server copy, or the server ignores the change.
            tasks[selectedTask].updated_at   = nowMs();
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
            tasks[selectedTask].updated_at   = nowMs();
            tasks[selectedTask].needs_push   = true;
            if (strlen(jwtToken) > 0)
                Api::pushTask(jwtToken, tasks[selectedTask]);
            Storage::saveTasks(tasks, taskCount);
            appState = ST_TASK_LIST;
            showMessage("Task restored");
            return;
        }
        if (c == 'c' || c == 'C') {
            editTaskCatIdx = 0;
            // Find current category index
            for (int i = 0; i < catCount; i++) {
                if (strcmp(categories[i].id, tasks[selectedTask].category_id) == 0) {
                    editTaskCatIdx = i + 1;
                    break;
                }
            }
            appState = ST_EDIT_TASK_CATEGORY;
            return;
        }
        if (c == 'x' || c == 'X') {
            int64_t now64 = nowMs();
            tasks[selectedTask].deleted_at = now64;
            tasks[selectedTask].updated_at = now64;
            tasks[selectedTask].needs_push = true;
            if (strlen(jwtToken) > 0)
                Api::pushTask(jwtToken, tasks[selectedTask], nullptr, 0, now64);
            // Remove from local list
            for (int i = selectedTask; i < taskCount - 1; i++)
                tasks[i] = tasks[i + 1];
            taskCount--;
            if (selectedTask >= taskCount && taskCount > 0) selectedTask = taskCount - 1;
            Storage::saveTasks(tasks, taskCount);
            sortTasksByCategory();
            appState = ST_TASK_LIST;
            showMessage("Task eliminato");
            return;
        }
    }
}

static void onKeySetupAlarmMin(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) {
        if (c == '+' && setupAlarmMin < 60) setupAlarmMin++;
        if (c == '-' && setupAlarmMin >  0) setupAlarmMin--;
    }
    if (hasBack(ks))    { appState = ST_TASK_LIST; return; }
    if (ks.enter) appState = ST_SETUP_BREAK_MIN;
}

static void onKeySetupBreakMin(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) {
        if (c == '+' && setupBreakMin < 30) setupBreakMin++;
        if (c == '-' && setupBreakMin >  0) setupBreakMin--;
    }
    if (hasBack(ks)) { appState = ST_SETUP_ALARM_MIN; return; }
    if (ks.enter) appState = ST_SETUP_VOLUME;
}

static void onKeySetupVolume(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) {
        if (c == '+' && setupVolume < 10) setupVolume++;
        if (c == '-' && setupVolume >  0) setupVolume--;
    }
    if (hasBack(ks)) { appState = ST_SETUP_BREAK_MIN; return; }
    if (ks.enter) {
        Storage::saveAlarmBreak(setupAlarmMin, setupBreakMin);
        Storage::saveVolume(setupVolume);
        M5Cardputer.Speaker.setVolume(setupVolume * 25);
        appState = ST_TASK_LIST;
        showMessage("Impostazioni salvate!");
    }
}

static void onKeyEditTaskCategory(Keyboard_Class::KeysState& ks) {
    const int total = catCount + 1;
    if (hasBack(ks)) { appState = ST_TASK_ACTION; return; }
    for (char c : ks.word) {
        if (c == '.' && editTaskCatIdx < total - 1) editTaskCatIdx++;
        if (c == ';' && editTaskCatIdx > 0)         editTaskCatIdx--;
    }
    if (ks.enter) {
        if (editTaskCatIdx > 0 && editTaskCatIdx - 1 < catCount)
            strlcpy(tasks[selectedTask].category_id, categories[editTaskCatIdx - 1].id, sizeof(tasks[selectedTask].category_id));
        else
            tasks[selectedTask].category_id[0] = '\0';
        tasks[selectedTask].updated_at = nowMs();
        tasks[selectedTask].needs_push = true;
        if (strlen(jwtToken) > 0)
            Api::pushTask(jwtToken, tasks[selectedTask]);
        Storage::saveTasks(tasks, taskCount);
        sortTasksByCategory();
        appState = ST_TASK_LIST;
        showMessage("Categoria aggiornata!");
    }
}

static void onKeySetupSSID(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) { if (c == '`') continue; appendChar(inputSSID, sizeof(inputSSID), c); }
    if (ks.del) backspace(inputSSID);
    if (hasBack(ks))  { appState = ST_WIFI_SCAN_LIST; return; }
    if (ks.enter && strlen(inputSSID) > 0) appState = ST_SETUP_PASS;
}

static void onKeySetupPass(Keyboard_Class::KeysState& ks) {
    for (char c : ks.word) { if (c == '`') continue; appendChar(inputWPass, sizeof(inputWPass), c); }
    if (ks.del) backspace(inputWPass);
    if (hasBack(ks))  { appState = ST_WIFI_SCAN_LIST; return; }
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
    for (char c : ks.word) { if (c == '`') continue; appendChar(inputApiUrl, sizeof(inputApiUrl), c); }
    if (ks.del) backspace(inputApiUrl);
    if (hasBack(ks))  { appState = ST_SETUP_PASS; return; }

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

// ─── Setup ────────────────────────────────────────────────────────────────────
void setup() {
    auto cfg = M5.config();
    M5Cardputer.begin(cfg, true);
    M5Cardputer.Display.setRotation(1);
    M5Cardputer.Display.setBrightness(128);
    M5Cardputer.Speaker.begin();
    beepEnabled = Storage::getBeep();

    UI::init();
    Storage::init();
    setupAlarmMin = Storage::getAlarmMin();
    setupBreakMin = Storage::getBreakMin();
    setupVolume   = Storage::getVolume();
    M5Cardputer.Speaker.setVolume(setupVolume * 25);

    // Restore locally-persisted categories, tasks, and session log
    catCount       = Storage::loadCategories(categories, MAX_CATEGORIES);
    taskCount      = Storage::loadTasks(tasks, MAX_TASKS);
    sessionLogCount = Storage::loadSessionLog(sessionLog, MAX_SESSION_LOG);

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

    if (apiUrl.length() == 0) {
        // First-run: no server URL configured yet → go through setup
        inputSSID[0] = '\0'; inputWPass[0] = '\0'; inputApiUrl[0] = '\0';
        isEditingSettings = false;
        appState = ST_SETUP_API;
    } else {
        // Start directly in task list — WiFi connects on demand (sync key S)
        appState = ST_TASK_LIST;
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
            if (hasBack(ks)) {
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

    // ── Alarm at x-minute intervals ──
    if (appState == ST_TIMER_RUNNING) {
        int elaps    = Timer::elapsedSeconds();
        int alarmMin = Storage::getAlarmMin();
        if (alarmMin > 0 && elaps > 0) {
            int thisMin = elaps / 60;
            if (thisMin > 0 && thisMin % alarmMin == 0 && thisMin != lastAlarmMinute) {
                lastAlarmMinute = thisMin;
                beepAlarm();
            }
        }
    }

    // ── Break countdown ──
    if (appState == ST_TIMER_PAUSED && pauseCountdownSec > 0) {
        if (now - lastBreakTickMs >= 1000) {
            lastBreakTickMs = now;
            pauseCountdownSec--;
            if (pauseCountdownSec <= 0) {
                pauseCountdownSec = 0;
                beepBreakEnd();
                // Start nagging every minute until the user resumes
                int alarmMin = Storage::getAlarmMin();
                pauseNagSec  = (alarmMin > 0 ? alarmMin * 60 : 60);
                lastNagTickMs = now;
            }
        }
    }

    // ── Post-break nag (repeats until user resumes) ──
    if (appState == ST_TIMER_PAUSED && pauseNagSec > 0) {
        if (now - lastNagTickMs >= 1000) {
            lastNagTickMs = now;
            pauseNagSec--;
            if (pauseNagSec <= 0) {
                beepBreakEnd();
                int alarmMin = Storage::getAlarmMin();
                pauseNagSec  = (alarmMin > 0 ? alarmMin * 60 : 60);
            }
        }
    }

    // ── Keyboard input ──
    if (M5Cardputer.Keyboard.isChange() && M5Cardputer.Keyboard.isPressed()) {
        Keyboard_Class::KeysState ks = M5Cardputer.Keyboard.keysState();

        bool inTextInput = (appState == ST_LOGIN_EMAIL        || appState == ST_LOGIN_PASS        ||
                            appState == ST_REGISTER_EMAIL      || appState == ST_REGISTER_PASS     ||
                            appState == ST_NEW_TASK_NAME       || appState == ST_NEW_CATEGORY_NAME ||
                            appState == ST_SETUP_SSID          || appState == ST_SETUP_PASS        ||
                            appState == ST_SETUP_API           || appState == ST_RENAME_CATEGORY);
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
                (void)c;
            }
        }

        switch (appState) {
            case ST_TASK_LIST:          onKeyTaskList(ks);          break;
            case ST_CATEGORY_LIST:      onKeyCategoryList(ks);      break;
            case ST_NEW_CATEGORY_NAME:  onKeyNewCategoryName(ks);   break;
            case ST_NEW_CATEGORY_COLOR: onKeyNewCategoryColor(ks);  break;
            case ST_NEW_TASK_NAME:      onKeyNewTaskName(ks);       break;
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
                if (hasBack(ks)) appState = ST_TASK_LIST;
                break;
            case ST_TASK_ACTION:        onKeyTaskAction(ks);        break;
            case ST_REGISTER_EMAIL:     onKeyRegisterEmail(ks);     break;
            case ST_REGISTER_PASS:      onKeyRegisterPass(ks);      break;
            case ST_HELP:
                for (char c : ks.word) {
                    if (c == '.') { if (helpPage < 1) helpPage++; }
                    if (c == ';') { if (helpPage > 0) helpPage--; }
                }
                if (hasBack(ks)) appState = prevState;
                break;
            case ST_SETUP_SSID:         onKeySetupSSID(ks);         break;
            case ST_SETUP_PASS:         onKeySetupPass(ks);         break;
            case ST_SETUP_API:          onKeySetupApi(ks);          break;
            case ST_SETUP_ALARM_MIN:    onKeySetupAlarmMin(ks);     break;
            case ST_SETUP_BREAK_MIN:    onKeySetupBreakMin(ks);     break;
            case ST_SETUP_VOLUME:       onKeySetupVolume(ks);       break;
            case ST_EDIT_TASK_CATEGORY: onKeyEditTaskCategory(ks);  break;
            case ST_RENAME_CATEGORY:    onKeyRenameCategory(ks);    break;
            case ST_TASK_DETAIL:
                if (hasBack(ks)) appState = ST_TASK_LIST;
                if (!ks.word.empty()) {
                    for (char c : ks.word)
                        if (c == 'i' || c == 'I') { appState = ST_TASK_ACTION; break; }
                }
                break;
            default:                    break;
        }
    }

    // ── Render ──
    switch (appState) {
        case ST_TASK_LIST:
        case ST_SYNCING:
            computeTaskTotals(taskTotalSec);
            UI::drawTaskList(tasks, taskCount, selectedTask,
                             appState == ST_SYNCING, userEmail,
                             categories, catCount, taskTotalSec);
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

        case ST_NEW_TASK_NAME:
            UI::drawNewTaskName(inputTaskName, cursorVisible);
            break;

        case ST_NEW_TASK_CATEGORY:
            UI::drawNewTaskCategory(categories, catCount, inputTaskCatIdx);
            break;

        case ST_TIMER_RUNNING:
        case ST_TIMER_PAUSED: {
            const char* tname = (activeTaskIdx >= 0 && activeTaskIdx < taskCount)
                                ? tasks[activeTaskIdx].title : "";
            UI::drawTimer(Timer::elapsedSeconds(), tname, Timer::isPaused(), pauseCountdownSec);
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
            if (sessionLogScroll >= sessionLogCount) sessionLogScroll = max(0, sessionLogCount - 1);
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

        case ST_TASK_DETAIL: {
            const Task& dt = tasks[selectedTask];
            const char* catName     = "";
            const char* catColorHex = "";
            for (int ci = 0; ci < catCount; ci++) {
                if (strcmp(categories[ci].id, dt.category_id) == 0) {
                    catName     = categories[ci].name;
                    catColorHex = categories[ci].color;
                    break;
                }
            }
            int dtTotal = 0;
            for (int si = 0; si < sessionLogCount; si++)
                if (strcmp(sessionLog[si].taskId, dt.id) == 0)
                    dtTotal += sessionLog[si].durationSec;
            UI::drawTaskDetail(dt, catName, catColorHex, dtTotal);
            break;
        }

        case ST_HELP:
            UI::drawHelp(helpPage); break;

        case ST_SETUP_ALARM_MIN:
            UI::drawSetupAlarmMin(setupAlarmMin); break;

        case ST_SETUP_BREAK_MIN:
            UI::drawSetupBreakMin(setupBreakMin); break;

        case ST_SETUP_VOLUME:
            UI::drawSetupVolume(setupVolume); break;

        case ST_EDIT_TASK_CATEGORY:
            UI::drawEditTaskCategory(
                (selectedTask >= 0 && selectedTask < taskCount) ? tasks[selectedTask].title : "",
                categories, catCount, editTaskCatIdx);
            break;

        case ST_RENAME_CATEGORY:
            UI::drawRenameCategoryName(
                (selectedCat >= 0 && selectedCat < catCount) ? categories[selectedCat].name : "",
                inputCatName, cursorVisible);
            break;

        default: break;
    }

    delay(50);  // ~20 FPS
}
