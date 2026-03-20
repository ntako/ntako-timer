#pragma once
#include "types.h"

namespace Timer {
    void startCountUp();    // start a count-up (tracking) session
    void pause();
    void resume();
    void stop();

    int  elapsedSeconds();  // seconds elapsed since start
    bool isRunning();       // running and not paused
    bool isPaused();
}
