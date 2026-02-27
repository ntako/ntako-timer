#include <Arduino.h>
#include "timer_logic.h"
#include "config.h"

namespace Timer {

TimerPhase currentPhase       = PHASE_WORK;
int        completedPomodoros = 0;

static unsigned long _startMs         = 0;
static int           _durationSec     = 0;
static int           _pausedRemSec    = 0;
static int           _pausedElapsedSec = 0;
static bool          _running         = false;
static bool          _paused          = false;
static bool          _countUp         = false;

void start(int durationSec) {
    _durationSec      = durationSec;
    _startMs          = millis();
    _pausedRemSec     = 0;
    _pausedElapsedSec = 0;
    _running          = true;
    _paused           = false;
    _countUp          = false;
}

void startCountUp() {
    _durationSec      = 0;
    _startMs          = millis();
    _pausedRemSec     = 0;
    _pausedElapsedSec = 0;
    _running          = true;
    _paused           = false;
    _countUp          = true;
}

void pause() {
    if (!_running || _paused) return;
    if (_countUp) _pausedElapsedSec = elapsedSeconds();
    else          _pausedRemSec     = remainingSeconds();
    _paused = true;
}

void resume() {
    if (!_running || !_paused) return;
    if (_countUp) {
        // Rebase start so elapsed continues from where it was
        _startMs = millis() - (unsigned long)_pausedElapsedSec * 1000UL;
    } else {
        // Rebase start so remaining continues
        _startMs = millis() - (unsigned long)(_durationSec - _pausedRemSec) * 1000UL;
    }
    _paused = false;
}

void stop() {
    _running  = false;
    _paused   = false;
    _countUp  = false;
}

int elapsedSeconds() {
    if (!_running) return 0;
    if (_paused && _countUp) return _pausedElapsedSec;
    return (int)((millis() - _startMs) / 1000UL);
}

int remainingSeconds() {
    if (!_running || _countUp) return 0;
    if (_paused) return _pausedRemSec;
    unsigned long elapsed = (millis() - _startMs) / 1000UL;
    int rem = _durationSec - (int)elapsed;
    return rem > 0 ? rem : 0;
}

bool isRunning()  { return _running && !_paused; }
bool isPaused()   { return _running && _paused;  }
bool isCountUp()  { return _countUp; }
bool isComplete() { return _running && !_paused && !_countUp && remainingSeconds() == 0; }

TimerPhase advancePhase() {
    TimerPhase next;
    if (currentPhase == PHASE_WORK) {
        completedPomodoros++;
        next = (completedPomodoros % CFG_POMODOROS_LONG == 0)
               ? PHASE_LONG_BREAK : PHASE_SHORT_BREAK;
    } else {
        next = PHASE_WORK;
    }
    currentPhase = next;
    return next;
}

} // namespace Timer
