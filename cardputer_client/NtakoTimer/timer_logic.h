#pragma once
#include "types.h"

namespace Timer {
    extern TimerPhase currentPhase;
    extern int        completedPomodoros;

    void start(int durationSec);
    void pause();
    void resume();
    void stop();

    int  remainingSeconds();
    int  elapsedSeconds();  // seconds elapsed since start (works in both modes)
    bool isRunning();       // running and not paused
    bool isPaused();
    bool isComplete();      // running, not paused, remaining == 0 (always false in count-up)
    bool isCountUp();       // true when in tracking / count-up mode

    void startCountUp();    // start a count-up (tracking) session

    // Advances phase after a work session completes. Updates currentPhase.
    // Returns the next phase (already applied).
    TimerPhase advancePhase();
}
