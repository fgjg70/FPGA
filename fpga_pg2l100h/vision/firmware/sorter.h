#ifndef SORTER_H
#define SORTER_H

#include <stdint.h>

enum sorter_mode { SORTER_OFF, SORTER_CAPS };
#define SORTER_FEED_TICKS (CLOCK_HZ * 5u)
#define SORTER_PREOPEN_TICKS (CLOCK_HZ / 4u)
#define SORTER_RELEASE_TICKS (CLOCK_HZ / 2u)
#define SORTER_GATE_TICKS (CLOCK_HZ * 2u)
#define SORTER_RESULT_TICKS CLOCK_HZ
static const unsigned short sorter_home_us[7] = {1500, 1500, 1500, 1500, 1500, 1500, 1500};
static const unsigned short sorter_action_us[7] = {2000, 2000, 2000, 2000, 2000, 2000, 2000};

typedef struct {
    unsigned mode;
    unsigned enabled;
    unsigned dirty;
    unsigned pulse[7];
    unsigned phase;
    unsigned target;
    unsigned latest;
    unsigned latest_valid;
    unsigned cap_candidate;
    unsigned cap_stable;
    unsigned drops;
    uint32_t next_feed;
    uint32_t restore_at;
    uint32_t close_at;
    uint32_t observed_at;
    uint32_t released_at;
} sorter_state;

static int sorter_due(uint32_t now, uint32_t deadline) {
    return (int32_t)(now - deadline) >= 0;
}

static void sorter_position(sorter_state *state, unsigned number, unsigned action) {
    unsigned value = action ? sorter_action_us[number - 1] : sorter_home_us[number - 1];
    if (state->pulse[number - 1] != value) {
        state->pulse[number - 1] = value;
        state->dirty |= 1u << (number - 1);
    }
}

static void sorter_select(sorter_state *state, unsigned mode, uint32_t now) {
    state->mode = mode;
    state->phase = 0;
    state->latest_valid = 0;
    state->cap_candidate = 0;
    state->cap_stable = 0;
    state->target = 0;
    state->next_feed = now + SORTER_FEED_TICKS;
    state->released_at = now;
    if (mode == SORTER_CAPS) state->enabled = 15;
    for (unsigned number = 1; number <= 7; number++) sorter_position(state, number, 0);
    state->dirty |= 127u;
}

static unsigned sorter_cap_gate(unsigned category) {
    switch (category) {
        case 2: return 2;
        case 3: return 3;
        case 0: return 4;
        default: return 0;
    }
}

static void sorter_observe(sorter_state *state, unsigned count, unsigned category, uint32_t captured_at, uint32_t now) {
    if (state->mode != SORTER_CAPS || !sorter_due(captured_at, state->released_at) ||
        !sorter_due(now, captured_at) || now - captured_at > SORTER_RESULT_TICKS ||
        (state->latest_valid && !sorter_due(captured_at, state->observed_at))) return;
    unsigned gate = count == 1 ? sorter_cap_gate(category) : 0;
    if (gate != state->cap_candidate) { state->cap_candidate = gate; state->cap_stable = 0; }
    if (gate && state->cap_stable < 2) state->cap_stable++;
    state->latest = gate;
    state->latest_valid = gate && state->cap_stable >= 2;
    state->observed_at = captured_at;
}

static void sorter_tick(sorter_state *state, uint32_t now) {
    if (state->mode != SORTER_CAPS) return;
    if (!state->phase && sorter_due(now, state->next_feed - SORTER_PREOPEN_TICKS)) {
        state->target = state->latest_valid && now - state->observed_at <= SORTER_RESULT_TICKS ? state->latest : 0;
        if (state->target) sorter_position(state, state->target, 1);
        if (sorter_due(now, state->next_feed)) state->next_feed = now + SORTER_PREOPEN_TICKS;
        state->phase = 1;
    }
    if (state->phase == 1 && sorter_due(now, state->next_feed)) {
        sorter_position(state, 1, 1);
        state->restore_at = now + SORTER_RELEASE_TICKS;
        state->close_at = now + SORTER_GATE_TICKS;
        state->released_at = state->restore_at;
        state->latest_valid = 0;
        state->cap_candidate = 0;
        state->cap_stable = 0;
        state->drops++;
        state->next_feed += SORTER_FEED_TICKS;
        if (sorter_due(now, state->next_feed)) state->next_feed = now + SORTER_FEED_TICKS;
        state->phase = 2;
    }
    if (state->phase == 2) {
        if (sorter_due(now, state->restore_at)) sorter_position(state, 1, 0);
        if (sorter_due(now, state->close_at)) {
            if (state->target) sorter_position(state, state->target, 0);
            state->phase = 0;
        }
    }
}

#endif
