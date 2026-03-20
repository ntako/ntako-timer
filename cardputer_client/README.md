# NTAKO Timer — Cardputer Client

Time tracker client for the **M5Stack Cardputer** (ESP32-S3).
Connects to the same PHP backend as the Flutter app to sync tasks and sessions.

---

## Features

- WiFi connection + NTP time sync
- Login with email/password (JWT stored in flash)
- Download task list from server (`/sync/pull`)
- Select a task and start a count-up timer
- Create new tasks directly on the device
- Push completed sessions and task updates to the server (`/sync/push`)

---

## Hardware

| Item | Spec |
|---|---|
| Board | M5Stack Cardputer |
| MCU | ESP32-S3 |
| Display | 1.14" IPS LCD — 240 × 135 px |
| Input | Built-in QWERTY keyboard |
| Connectivity | WiFi 802.11 b/g/n |

---

## Prerequisites

- [PlatformIO](https://platformio.org/) (VSCode extension or CLI)
- USB-C cable

---

## Configuration

Edit `include/config.h` before building:

```cpp
#define WIFI_SSID     "your_wifi_ssid"
#define WIFI_PASSWORD "your_wifi_password"

// Same server as the Flutter app:
#define API_BASE_URL  "https://yourdomain.com/api"
// For local dev on the same LAN as your Docker PC:
// #define API_BASE_URL "http://192.168.1.100:8080/api"
```

> **Note**: `config.h` is not committed to git — add it to `.gitignore` if you fork the repo.

---

## Build & Flash

```bash
cd cardputer_client

# Build only
pio run

# Build + flash
pio run --target upload

# Open serial monitor (115200 baud)
pio device monitor
```

PlatformIO will automatically download the M5Cardputer and ArduinoJson libraries on first build.

---

## Usage

### Key bindings

| Screen | Key | Action |
|---|---|---|
| Task list | `j` / `k` | Navigate up/down |
| Task list | `ENTER` | Start timer on selected task |
| Task list | `N` | Create a new task |
| Task list | `S` | Sync with server |
| Task list | `L` | Login / switch account |
| Timer | `SPACE` or `P` | Pause / resume |
| Timer | `X` | Stop and return to task list |
| Timer (paused) | `ENTER` | Resume |
| Login / input | `DEL` | Backspace |
| Login / input | `FN` | Cancel / go back |
### First run flow

1. Device connects to WiFi (shows dots).
2. If a JWT was previously saved, tasks are synced immediately.
3. Otherwise press `L` to log in with your account credentials.
4. After login the task list is pulled from the server.
5. Select a task with `j`/`k` and press `ENTER` to start.

### Offline mode

If WiFi is unavailable (30 s timeout), the device enters offline mode.
Tasks created offline are kept in RAM and pushed to the server on the next successful sync.

> Tasks are **not** persisted to flash — they live in RAM only. A reboot without sync will lose locally-created tasks. Log in and press `S` before powering off.

---

## Project structure

```
cardputer_client/
├── platformio.ini
├── include/
│   ├── config.h         ← WiFi + API URL — edit before flashing
│   ├── types.h          ← shared structs and enums
│   ├── storage.h        ← NVS (flash) helpers
│   ├── api_client.h     ← HTTP calls to PHP backend
│   ├── timer_logic.h    ← Count-up timer state
│   └── ui.h             ← display rendering
└── src/
    ├── main.cpp         ← state machine + keyboard handling
    ├── storage.cpp
    ├── api_client.cpp
    ├── timer_logic.cpp
    └── ui.cpp
```

---

## HTTPS & certificates

The API client calls `setInsecure()` on the TLS socket, which skips certificate
validation. This is acceptable for a personal device on a trusted network.
For stricter security, embed the server's root CA in `api_client.cpp` and call
`_secClient.setCACert(rootCACertificate)` instead.
