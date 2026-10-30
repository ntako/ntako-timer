#include <Arduino.h>
#include "api_client.h"
#include "config.h"
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include <ArduinoJson.h>
#include <sys/time.h>

static char _baseUrl[128] = "";

// Shown when the server rejects the token (expired, or JWT secret changed).
static const char* LOGIN_EXPIRED = "Login scaduto: rifai l'accesso";

void Api::init(const char* baseUrl) {
    strlcpy(_baseUrl, baseUrl, sizeof(_baseUrl));
}

// Single shared secure client — avoids repeated heap allocation.
static WiFiClientSecure _secClient;

static void httpBegin(HTTPClient& http, const String& url) {
    if (url.startsWith("https://")) {
        _secClient.setInsecure(); // personal/dev use — skip cert validation
        http.begin(_secClient, url);
    } else {
        http.begin(url);
    }
}

static bool doPost(const char* path, const String& body, const char* token,
                   JsonDocument& out, char* outErr, size_t errSize) {
    HTTPClient http;
    httpBegin(http, String(_baseUrl) + path);
    http.addHeader("Content-Type", "application/json");
    if (token && strlen(token) > 0)
        http.addHeader("Authorization", String("Bearer ") + token);
    http.setTimeout(10000);

    int code = http.POST((uint8_t*)body.c_str(), body.length());
    if (code < 0) {
        snprintf(outErr, errSize, "HTTP err %d", code);
        http.end();
        return false;
    }

    String respBody = http.getString();
    http.end();

    DeserializationError err = deserializeJson(out, respBody);
    if (code == 401) { snprintf(outErr, errSize, "%s", LOGIN_EXPIRED); return false; }
    if (err) { snprintf(outErr, errSize, "HTTP%d %.16s", code, respBody.c_str()); return false; }
    if (code >= 400) {
        snprintf(outErr, errSize, "%s (%d)",
                 out["error"] | "Server error", code);
        return false;
    }
    return true;
}

// With a filter, only the fields it lists are kept: the body is parsed
// straight from the stream, so fields the device doesn't use (long task
// descriptions, deleted rows' details…) never take RAM.
static bool doGet(const char* path, const char* token,
                  JsonDocument& out, char* outErr, size_t errSize,
                  const JsonDocument* filter = nullptr) {
    HTTPClient http;
    // HTTP/1.0: no chunked transfer encoding, so the stream is plain JSON.
    http.useHTTP10(true);
    httpBegin(http, String(_baseUrl) + path);
    if (token && strlen(token) > 0)
        http.addHeader("Authorization", String("Bearer ") + token);
    http.setTimeout(10000);

    int code = http.GET();
    if (code < 0) {
        snprintf(outErr, errSize, "HTTP err %d", code);
        http.end();
        return false;
    }

    DeserializationError err = filter
        ? deserializeJson(out, http.getStream(), DeserializationOption::Filter(*filter))
        : deserializeJson(out, http.getStream());
    http.end();

    if (code == 401) { snprintf(outErr, errSize, "%s", LOGIN_EXPIRED); return false; }
    if (err) { snprintf(outErr, errSize, "HTTP%d JSON: %s", code, err.c_str()); return false; }
    if (code >= 400) {
        snprintf(outErr, errSize, "%s (%d)",
                 out["error"] | "Server error", code);
        return false;
    }
    return true;
}

// ─── Public API ──────────────────────────────────────────────────────────────

bool Api::login(const char* email, const char* password,
                char* outToken, size_t tokenSize,
                char* outErr,   size_t errSize) {
    JsonDocument body;
    body["email"]    = email;
    body["password"] = password;
    String bodyStr;
    serializeJson(body, bodyStr);

    JsonDocument resp;
    if (!doPost("/auth/login", bodyStr, nullptr, resp, outErr, errSize))
        return false;

    const char* tok = resp["token"];
    if (!tok) { snprintf(outErr, errSize, "No token"); return false; }
    strlcpy(outToken, tok, tokenSize);
    return true;
}

bool Api::registerUser(const char* email, const char* password,
                       char* outToken, size_t tokenSize,
                       char* outErr,   size_t errSize) {
    JsonDocument body;
    body["email"]    = email;
    body["password"] = password;
    String bodyStr;
    serializeJson(body, bodyStr);

    JsonDocument resp;
    if (!doPost("/auth/register", bodyStr, nullptr, resp, outErr, errSize))
        return false;

    const char* tok = resp["token"];
    if (!tok) { snprintf(outErr, errSize, "No token"); return false; }
    strlcpy(outToken, tok, tokenSize);
    return true;
}

int Api::pull(const char* token, int64_t since,
              Category* cats, int maxCats, int& catCount,
              Task* tasks, int maxTasks, int64_t& serverTime,
              SessionEntry* sessions, int maxSessions, int* sessionCount,
              char* outErr, size_t errSize) {
    char path[48];
    snprintf(path, sizeof(path), "/sync/pull?since=%lld", since);

    // Only the fields read below.
    JsonDocument filter;
    filter["server_time"] = true;
    filter["error"]       = true;
    for (const char* k : {"client_id", "id", "name", "color", "deleted_at"})
        filter["categories"][0][k] = true;
    for (const char* k : {"client_id", "category_client_id", "id", "title",
                          "is_completed", "updated_at", "created_at", "deleted_at"})
        filter["tasks"][0][k] = true;
    for (const char* k : {"client_id", "task_client_id", "duration_seconds",
                          "started_at", "ended_at"})
        filter["sessions"][0][k] = true;

    char err[64];
    JsonDocument resp;
    if (!doGet(path, token, resp, err, sizeof(err), &filter)) {
        if (outErr && errSize > 0) strlcpy(outErr, err, errSize);
        return -1;
    }

    serverTime = resp["server_time"] | (int64_t)0;

    // ── Categories ──
    catCount = 0;
    if (cats && maxCats > 0) {
        JsonArray carr = resp["categories"].as<JsonArray>();
        if (!carr.isNull()) {
            for (JsonObject c : carr) {
                if (catCount >= maxCats) break;
                int64_t deleted_at = c["deleted_at"] | (int64_t)0;
                if (deleted_at != 0) continue; // skip soft-deleted
                Category& cat = cats[catCount];
                strlcpy(cat.id,    c["client_id"] | "", sizeof(cat.id));
                cat.server_id = c["id"] | 0;
                strlcpy(cat.name,  c["name"]  | "?",       sizeof(cat.name));
                strlcpy(cat.color, c["color"] | "#6366f1", sizeof(cat.color));
                cat.needs_push = false;
                catCount++;
            }
        }
    }

    // ── Tasks ──
    JsonArray arr = resp["tasks"].as<JsonArray>();
    int count = 0;
    if (!arr.isNull()) {
        for (JsonObject t : arr) {
            if (count >= maxTasks) break;
            Task& tk = tasks[count];
            strlcpy(tk.id,          t["client_id"]         | "", sizeof(tk.id));
            strlcpy(tk.category_id, t["category_client_id"] | "", sizeof(tk.category_id));
            tk.server_id      = t["id"] | 0;
            strlcpy(tk.title, t["title"] | "Untitled", sizeof(tk.title));
            tk.is_completed   = (int)(t["is_completed"] | 0) != 0;
            tk.updated_at     = t["updated_at"] | (int64_t)0;
            tk.created_at     = t["created_at"] | (int64_t)0;
            tk.needs_push     = false;

            int64_t deleted_at = t["deleted_at"] | (int64_t)0;
            if (!tk.is_completed && deleted_at == 0 && strlen(tk.id) > 0)
                count++;
        }
    }

    // ── Sessions (optional) ──
    if (sessions && maxSessions > 0 && sessionCount) {
        *sessionCount = 0;
        JsonArray sarr = resp["sessions"].as<JsonArray>();
        if (!sarr.isNull()) {
            for (JsonObject s : sarr) {
                if (*sessionCount >= maxSessions) break;
                SessionEntry& se = sessions[*sessionCount];
                strlcpy(se.clientId, s["client_id"]      | "", sizeof(se.clientId));
                strlcpy(se.taskId,   s["task_client_id"] | "", sizeof(se.taskId));
                // taskName resolved by caller from taskId
                se.taskName[0]  = '\0';
                se.durationSec  = s["duration_seconds"] | 0;
                se.startedAt    = (int64_t)(s["started_at"] | (long long)0);
                se.endedAt      = (int64_t)(s["ended_at"]   | (long long)0);
                se.needs_push   = false;  // already on server
                (*sessionCount)++;
            }
        }
    }

    return count;
}

bool Api::pushCategory(const char* token, Category& cat, char* outErr, size_t errSize) {
    // Wall-clock ms. Before NTP has synced this is near epoch 0, and the
    // server substitutes its own time.
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    int64_t now = (int64_t)tv.tv_sec * 1000LL + tv.tv_usec / 1000LL;
    JsonDocument body;
    body["tasks"].to<JsonArray>();
    body["sessions"].to<JsonArray>();
    JsonArray cats = body["categories"].to<JsonArray>();
    JsonObject c   = cats.add<JsonObject>();
    c["client_id"]  = cat.id;
    c["name"]       = cat.name;
    c["color"]      = cat.color;
    c["created_at"] = now;
    c["updated_at"] = now;

    String bodyStr;
    serializeJson(body, bodyStr);

    char err[64];
    JsonDocument resp;
    if (!doPost("/sync/push", bodyStr, token, resp, err, sizeof(err))) {
        if (outErr && errSize > 0) strlcpy(outErr, err, errSize);
        return false;
    }

    JsonArray synced = resp["synced_categories"].as<JsonArray>();
    if (!synced.isNull()) {
        for (JsonObject sc : synced) {
            if (strcmp(sc["client_id"] | "", cat.id) == 0) {
                cat.server_id  = sc["server_id"] | 0;
                cat.needs_push = false;
                break;
            }
        }
    }
    return true;
}

bool Api::pushTask(const char* token, Task& task, char* outErr, size_t errSize, int64_t deletedAt) {
    JsonDocument body;
    body["categories"].to<JsonArray>();
    JsonArray tasks = body["tasks"].to<JsonArray>();
    JsonObject t    = tasks.add<JsonObject>();
    t["client_id"]            = task.id;
    t["category_client_id"]   = strlen(task.category_id) > 0 ? task.category_id : nullptr;
    // Title only while the server doesn't know the task yet: on the device it
    // can't be renamed and is cut to MAX_TITLE_LEN - 1 chars, so resending it
    // would truncate a longer title set elsewhere. The description is never
    // sent (the device doesn't hold it): the server keeps fields not sent.
    if (task.server_id == 0) t["title"] = task.title;
    t["type"]                 = "tracker";
    t["is_completed"]         = task.is_completed ? 1 : 0;
    t["created_at"]           = task.created_at;
    t["updated_at"]           = task.updated_at;
    if (deletedAt > 0) t["deleted_at"] = deletedAt;
    body["sessions"].to<JsonArray>();

    String bodyStr;
    serializeJson(body, bodyStr);

    char err[64];
    JsonDocument resp;
    if (!doPost("/sync/push", bodyStr, token, resp, err, sizeof(err))) {
        if (outErr && errSize > 0) strlcpy(outErr, err, errSize);
        return false;
    }

    JsonArray synced = resp["synced_tasks"].as<JsonArray>();
    if (!synced.isNull()) {
        for (JsonObject st : synced) {
            if (strcmp(st["client_id"] | "", task.id) == 0) {
                task.server_id  = st["server_id"] | 0;
                task.needs_push = false;
                break;
            }
        }
    }
    return true;
}

bool Api::pushSession(const char* token,
                      const char* sessionId, const char* taskClientId,
                      const char* type,
                      int64_t startedAt, int64_t endedAt, int durationSec) {
    JsonDocument body;
    body["categories"].to<JsonArray>();
    body["tasks"].to<JsonArray>();
    JsonArray sessions = body["sessions"].to<JsonArray>();
    JsonObject s = sessions.add<JsonObject>();
    s["client_id"]        = sessionId;
    s["task_client_id"]   = taskClientId;
    s["type"]             = type;
    s["started_at"]       = startedAt;
    // endedAt 0 = still running: pushed open so the other clients show it.
    if (endedAt > 0) s["ended_at"] = endedAt;
    else             s["ended_at"] = nullptr;
    s["duration_seconds"] = durationSec;
    s["is_completed"]     = endedAt > 0 ? 1 : 0;
    s["created_at"]       = startedAt;

    String bodyStr;
    serializeJson(body, bodyStr);

    char err[64];
    JsonDocument resp;
    return doPost("/sync/push", bodyStr, token, resp, err, sizeof(err));
}
