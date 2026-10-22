#pragma once
#include <Arduino.h>
#include "types.h"

namespace Api {
    // Must be called once at startup with the base URL read from storage.
    void init(const char* baseUrl);

    // Returns true on success; fills outToken/outErr.
    bool login(const char* email, const char* password,
               char* outToken, size_t tokenSize,
               char* outErr,   size_t errSize);

    // Create a new account. Returns true on success; fills outToken/outErr.
    bool registerUser(const char* email, const char* password,
                      char* outToken, size_t tokenSize,
                      char* outErr,   size_t errSize);

    // Fetches categories, tasks and sessions modified after `since` ms.
    // Fills cats[] and tasks[]; returns task count, -1 on error.
    // serverTime set to server's current time (ms).
    // sessions[] is populated with up to maxSessions entries; sessionCount is set.
    int pull(const char* token, int64_t since,
             Category* cats, int maxCats, int& catCount,
             Task* tasks, int maxTasks, int64_t& serverTime,
             SessionEntry* sessions = nullptr,
             int maxSessions = 0, int* sessionCount = nullptr,
             char* outErr = nullptr, size_t errSize = 0);

    // Pushes a single category; updates cat.server_id on success.
    bool pushCategory(const char* token, Category& cat,
                      char* outErr = nullptr, size_t errSize = 0);

    // Pushes a single task; updates task.server_id on success. Returns true on success.
    // outErr (optional) receives the server error string on failure.
    // deletedAt (optional) sends deleted_at timestamp in JSON if > 0.
    bool pushTask(const char* token, Task& task,
                  char* outErr = nullptr, size_t errSize = 0,
                  int64_t deletedAt = 0);

    // Pushes a session; endedAt 0 pushes it as still running (the other
    // clients then show it). Returns true on success.
    bool pushSession(const char* token,
                     const char* sessionId,
                     const char* taskClientId,
                     const char* type,        // "work" | "short_break" | "long_break" | "tracking"
                     int64_t startedAt, int64_t endedAt, int durationSec);
}
