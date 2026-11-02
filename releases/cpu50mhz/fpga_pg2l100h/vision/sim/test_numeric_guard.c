#include <assert.h>
#include <stdio.h>
#include "../firmware/numeric_guard.h"

static void empty_scene(numeric_guard *guard) {
    for (int frame = 0; frame < 3; frame++) assert(!guard_observe(guard, OBS_EMPTY, -1, 0, 0));
    assert(guard->armed && guard->status == GUARD_EMPTY);
}

static void present(numeric_guard *guard, int digit) {
    assert(!guard_observe(guard, OBS_VALID, digit, 30, 30));
    assert(!guard_observe(guard, OBS_VALID, digit, 31, 30));
    assert(guard_observe(guard, OBS_VALID, digit, 30, 31));
}

int main(void) {
    numeric_guard guard = {0};
    guard_expected(&guard, 3);
    for (int frame = 0; frame < 10; frame++) assert(!guard_observe(&guard, OBS_VALID, 3, 30, 30));
    assert(!guard.passed && !guard.rejected);
    empty_scene(&guard);
    present(&guard, 3);
    assert(guard.status == GUARD_MATCH && guard.passed == 1 && guard.sequence == 1);
    for (int frame = 0; frame < 20; frame++) assert(!guard_observe(&guard, OBS_VALID, 3, 30, 30));
    assert(guard.passed == 1);
    assert(!guard_observe(&guard, OBS_VALID, 4, 30, 30));
    assert(guard.status == GUARD_REMOVE && guard.passed == 1 && !guard.rejected);
    for (int frame = 0; frame < 5; frame++) assert(!guard_observe(&guard, OBS_UNCERTAIN, -1, 0, 0));
    assert(!guard.armed);
    empty_scene(&guard);
    present(&guard, 4);
    assert(guard.status == GUARD_WRONG && guard.rejected == 1 && guard.sequence == 2);
    empty_scene(&guard);
    assert(!guard_observe(&guard, OBS_VALID, 3, 20, 20));
    assert(!guard_observe(&guard, OBS_VALID, 3, 50, 20));
    assert(guard.stable == 1);
    assert(!guard_observe(&guard, OBS_UNCERTAIN, -1, 0, 0));
    assert(!guard.stable);
    for (int frame = 0; frame < 12; frame++) assert(!guard_observe(&guard, OBS_VALID, frame % 2 ? 2 : 3, 30, 30));
    assert(guard.passed == 1 && guard.rejected == 1);
    guard_observe(&guard, OBS_FAULT, -1, 0, 0);
    assert(guard.status == GUARD_FAULT && !guard.armed);
    assert(!guard_observe(&guard, OBS_VALID, 3, 30, 30));
    guard_expected(&guard, 4);
    assert(!guard.armed && guard.expected == 4 && guard.passed == 1);
    empty_scene(&guard);
    present(&guard, 4);
    assert(guard.status == GUARD_MATCH && guard.passed == 2 && guard.sequence == 3);
    guard_observe(&guard, OBS_EMPTY, -1, 0, 0);
    guard_observe(&guard, OBS_EMPTY, -1, 0, 0);
    guard_observe(&guard, OBS_UNCERTAIN, -1, 0, 0);
    assert(!guard.armed && !guard.empty);
    puts("PASS numeric guard: startup/rearm, 3-frame agreement, wrong-label rejection, duplicate suppression, motion, uncertainty, fault and target changes");
    return 0;
}
