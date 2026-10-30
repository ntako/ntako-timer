# Workadoro — Cardputer Client

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

- Arduino IDE 2 with the ESP32 boards package (board: **M5Stack Cardputer**)
- Libraries: **M5Cardputer** and **ArduinoJson 7.x** (Library Manager)
- USB-C cable

---

## Configuration

The device reads its settings from `/workadoro.json`, on the TF card if one
is inserted, otherwise on the internal flash (LittleFS). Copy
`workadoro.example.json` to the card as `workadoro.json` and set at least
`api_url` and your Wi-Fi networks:

```json
{
  "api_url": "https://yourdomain.com/api",
  "wifi": [{"ssid": "HomeSSID", "pass": "HomePassword"}]
}
```

Login token and email are written to the same file after logging in on the
device. Devices set up before the rename (NTAKO Timer) keep working: on the
first start the old `ntako_*` files are renamed to the new names.

---

## Build & Flash

Open `Workadoro/Workadoro.ino` in Arduino IDE, select the Cardputer board and
its port, then **Upload**. The firmware is about 1.3 MB: pick a partition
scheme with room for it (Tools → Partition Scheme → *Huge APP*); the default
1.2 MB one is too small.

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
Categories, tasks and finished sessions are saved on the card (or flash) and
pushed to the server on the next successful sync (`S`).

---

## Project structure

```
cardputer_client/
├── workadoro.example.json  ← settings template (copy to the card)
└── Workadoro/
    ├── Workadoro.ino       ← state machine + keyboard handling
    ├── config.h            ← constants (NVS keys, display, limits)
    ├── types.h             ← shared structs and enums
    ├── storage.*           ← settings file, data files, NVS
    ├── api_client.*        ← HTTP calls to the PHP backend
    ├── timer_logic.*       ← count-up timer state
    └── ui.*                ← display rendering
```

---

## HTTPS & certificates

The API client calls `setInsecure()` on the TLS socket, which skips certificate
validation. This is acceptable for a personal device on a trusted network.
For stricter security, embed the server's root CA in `api_client.cpp` and call
`_secClient.setCACert(rootCACertificate)` instead.
