#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static volatile uint32_t registers[36];
static volatile uint32_t results[432];
static unsigned result_reads;

static volatile uint32_t *test_register(uint32_t offset) {
    if (offset == 0x14) {
        result_reads++;
        assert(registers[0x10 / 4] < 432);
        return &results[registers[0x10 / 4]];
    }
    assert(offset / 4 < 36);
    return &registers[offset / 4];
}

#define REG(offset) (*test_register(offset))
#define main application_main
#include "numeric_main_fixture.c"
#undef main

static void clear_scene(void) {
    for (unsigned frame = 0; frame < 3; frame++) guard_observe(&guard, OBS_EMPTY, -1, 0, 0);
}

static void result_for_class(unsigned class_id) {
    for (unsigned index = 0; index < 432; index++) results[index] = 0;
    unsigned offset = 5 * 27;
    results[offset] = 110;
    results[offset + 1] = 64;
    results[offset + 2] = 64;
    results[offset + 3] = 80;
    results[offset + 4] = 80;
    results[offset + 5 + class_id] = 120;
}

int main(void) {
    registers[0x64 / 4] = 3;
    select_mode(MODE_HANDWRITE);
    assert(application_mode == MODE_HANDWRITE && mode_ready);
    assert((registers[0x34 / 4] & 0x03800000u) == 0);
    cycle_mode();
    assert(guard.expected == 1 && registers[0x5c / 4] == 1);
    for (unsigned number = 1; number <= 9; number++) {
        guard_expected(&guard, number);
        clear_scene();
        result_for_class(number + 2);
        for (unsigned frame = 0; frame < 3; frame++) detect();
        assert(guard.status == GUARD_MATCH && guard.digit == (int)number);
        assert((registers[0x28 / 4] & 0x8000003fu) == (0x80000000u | (number + 2)));
    }
    guard_expected(&guard, 10);
    clear_scene();
    result_for_class(2);
    for (unsigned frame = 0; frame < 3; frame++) detect();
#if GESTURE_DIGIT_MAX == 10
    assert(guard.status == GUARD_MATCH && guard.digit == 10);
    assert((registers[0x28 / 4] & 0x8000003fu) == 0x80000002u);
    assert(((registers[0x34 / 4] >> 4) & 15u) == 10);
    assert(((registers[0x34 / 4] >> 8) & 15u) == 10);
#else
    assert(guard.status == GUARD_UNCERTAIN && registers[0x28 / 4] == 0);
#endif
    uint32_t previous_passed = guard.passed;
    uint32_t previous_rejected = guard.rejected;
    uint32_t previous_sequence = guard.sequence;
    result_reads = 0;
    dump_requested = 1;
    cycle_mode();
    assert(application_mode == MODE_COCO && !mode_ready && registers[0x5c / 4] == 2);
    assert(guard.status == GUARD_FAULT && guard.digit == -1 && !guard.stable && !guard.armed && !dump_requested);
    assert((registers[0x34 / 4] & 0x03800000u) == 0x03000000u);
    assert(registers[0x28 / 4] == 0);
    int previous_expected = guard.expected;
    next_target();
    result_for_class(12);
    for (unsigned frame = 0; frame < 3; frame++) detect();
    assert(result_reads == 0 && registers[0x28 / 4] == 0);
    assert(guard.expected == previous_expected && guard.status == GUARD_FAULT);
    assert(guard.passed == previous_passed && guard.rejected == previous_rejected && guard.sequence == previous_sequence);
    select_mode(MODE_COUNT);
    assert(application_mode == MODE_COCO && registers[0x5c / 4] == 2);
    cycle_mode();
    assert(application_mode == MODE_HANDWRITE && mode_ready);
    assert((registers[0x34 / 4] & 0x03800000u) == 0);
    select_mode(0);
    assert(guard.expected == 0 && registers[0x5c / 4] == 0);
    for (unsigned number = 0; number < 10; number++) {
        guard_expected(&guard, number);
        clear_scene();
        result_for_class(12 + number);
        for (unsigned frame = 0; frame < 3; frame++) detect();
        assert(guard.status == GUARD_MATCH && guard.digit == (int)number);
        assert((registers[0x28 / 4] & 0x8000003fu) == (0x8000000cu + number));
    }
    next_target();
    assert(guard.expected == 0);
    select_mode(MODE_GESTURE);
    guard_expected(&guard, GESTURE_DIGIT_MAX);
    next_target();
    assert(guard.expected == 1);
    registers[0x64 / 4] = 1;
    select_mode(MODE_GESTURE);
    assert(!mode_ready && (registers[0x34 / 4] & 0x02000000u));
    assert(guard.status == GUARD_FAULT && registers[0x28 / 4] == 0);
    printf("PASS firmware hand %d: three-mode cycle, ten activation gate, all numeric classes, missing-model interlock, preserved counters and target wrap\n", GESTURE_DIGIT_MAX);
    return 0;
}
