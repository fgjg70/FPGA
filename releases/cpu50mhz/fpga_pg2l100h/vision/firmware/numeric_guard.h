#ifndef NUMERIC_GUARD_H
#define NUMERIC_GUARD_H

#include <stdint.h>

enum guard_status { GUARD_EMPTY, GUARD_WAIT, GUARD_MATCH, GUARD_WRONG, GUARD_UNCERTAIN, GUARD_REMOVE, GUARD_FAULT };
enum guard_observation { OBS_EMPTY, OBS_VALID, OBS_UNCERTAIN, OBS_FAULT };

typedef struct {
    uint32_t passed;
    uint32_t rejected;
    uint32_t sequence;
    int expected;
    int digit;
    int candidate;
    int center_x;
    int center_y;
    unsigned stable;
    unsigned empty;
    unsigned armed;
    unsigned latched;
    enum guard_status status;
} numeric_guard;

static void guard_release(numeric_guard *guard) {
    guard->digit = -1;
    guard->candidate = -1;
    guard->stable = 0;
    guard->empty = 0;
    guard->armed = 0;
    guard->latched = 0;
    guard->status = GUARD_WAIT;
}

static void guard_expected(numeric_guard *guard, int expected) {
    guard->expected = expected;
    guard_release(guard);
}

static int guard_observe(numeric_guard *guard, enum guard_observation observation, int digit, int center_x, int center_y) {
    if (observation == OBS_FAULT) {
        guard_release(guard);
        guard->status = GUARD_FAULT;
        return 0;
    }
    if (observation == OBS_EMPTY) {
        guard->candidate = -1;
        guard->stable = 0;
        if (guard->empty < 3) guard->empty++;
        if (guard->empty == 3) {
            guard->armed = 1;
            guard->latched = 0;
            guard->digit = -1;
            guard->status = GUARD_EMPTY;
        } else if (!guard->latched) guard->status = GUARD_WAIT;
        return 0;
    }
    guard->empty = 0;
    if (observation != OBS_VALID || digit < 0 || digit > 9) {
        guard->stable = 0;
        guard->candidate = -1;
        if (!guard->latched) guard->status = GUARD_UNCERTAIN;
        return 0;
    }
    if (guard->latched) {
        if (digit != guard->digit) guard->status = GUARD_REMOVE;
        return 0;
    }
    guard->digit = digit;
    if (!guard->armed) {
        guard->status = GUARD_REMOVE;
        return 0;
    }
    int delta_x = center_x - guard->center_x;
    int delta_y = center_y - guard->center_y;
    if (guard->candidate != digit || delta_x < -12 || delta_x > 12 || delta_y < -12 || delta_y > 12) guard->stable = 0;
    guard->candidate = digit;
    guard->center_x = center_x;
    guard->center_y = center_y;
    guard->stable++;
    guard->status = GUARD_WAIT;
    if (guard->stable < 3) return 0;
    guard->latched = 1;
    guard->armed = 0;
    guard->sequence++;
    if (digit == guard->expected) {
        guard->passed++;
        guard->status = GUARD_MATCH;
    } else {
        guard->rejected++;
        guard->status = GUARD_WRONG;
    }
    return 1;
}

#endif
