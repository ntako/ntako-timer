#include <Arduino.h>
#include "timer_logic.h"

namespace Timer {

static unsigned long _startMs         = 0;
static int           _pausedElapsedSec = 0;
static bool          _running         = false;
static bool          _paused          = false;

void startCountUp() {
    _startMs          = millis();
    _pausedElapsedSec = 0;
    _running          = true;
    _paused           = false;
}

void pause() {
    if (!_running || _paused) return;
    _pausedElapsedSec = elapsedSeconds();
    _paused = true;
}

void resume() {
    if (!_running || !_paused) return;
    // Rebase start so elapsed continues from where it was
    _startMs = millis() - (unsigned long)_pausedElapsedSec * 1000UL;
    _paused = false;
}

void stop() {
    _running = false;
    _paused  = false;
}

int elapsedSeconds() {
    if (!_running) return 0;
    if (_paused) return _pausedElapsedSec;
    return (int)((millis() - _startMs) / 1000UL);
}

bool isRunning() { return _running && !_paused; }
bool isPaused()  { return _running && _paused;  }

} // namespace Timer
