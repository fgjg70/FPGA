#include <stdint.h>
#include "model_info.h"
#include "numeric_guard.h"

#define REG(offset) (*(volatile uint32_t *)(0xa1000000u + (offset)))
#include "platform_clock.h"

static numeric_guard guard;
static unsigned object_score;
static unsigned class_margin;
static uint32_t decision_cycles;
static int dump_requested;
static unsigned gesture_mode;

static void serial_text(const char *text) {
    while (*text) {
        while (REG(0x84) & 1u) { }
        REG(0x80) = (uint8_t)*text++;
    }
}

static void serial_hex(uint32_t value) {
    const char *digits = "0123456789ABCDEF";
    for (int shift = 28; shift >= 0; shift -= 4) {
        char text[2] = {digits[(value >> shift) & 15u], 0};
        serial_text(text);
    }
}

static int32_t result_value(uint32_t index) {
    REG(0x10) = index;
    __asm__ volatile ("nop\nnop" ::: "memory");
    return (int32_t)REG(0x14);
}

static void dump_frame(void) {
    const char *digits = "0123456789ABCDEF";
    uint32_t checksum = 0xffffffffu;
    serial_text("Q7FRAME BEGIN\r\n");
    for (unsigned index = 0; index < 4096; index++) {
        REG(0x54) = index;
        __asm__ volatile ("nop\nnop" ::: "memory");
        unsigned value = REG(0x58) & 255u;
        char text[3] = {digits[value >> 4], digits[value & 15u], 0};
        serial_text(text);
        checksum ^= value;
        for (unsigned bit = 0; bit < 8; bit++) checksum = (checksum >> 1) ^ (0xedb88320u & (0u - (checksum & 1u)));
        if ((index & 63u) == 63u) serial_text("\r\n");
    }
    serial_text("Q7FRAME END "); serial_hex(~checksum); serial_text("\r\n");
    dump_requested = 0;
}

static int clamp(int value, int lower, int upper) {
    if (value < lower) return lower;
    if (value > upper) return upper;
    return value;
}

static void publish(void) {
    REG(0x34) = (uint32_t)guard.status | (uint32_t)guard.expected << 4 |
                (uint32_t)(guard.digit < 0 ? 15 : guard.digit) << 8 |
                guard.stable << 12 | guard.armed << 15 | object_score << 16 | gesture_mode << 23;
    REG(0x38) = guard.passed;
    REG(0x3c) = guard.rejected;
    REG(0x2c) = 1;
}

static void clear_overlay(void) {
    REG(0x28) = 0;
}

static void event_report(void) {
    serial_text("EVENT,"); serial_hex(guard.sequence);
    serial_text(","); serial_hex(REG(0x1c));
    serial_text(","); serial_hex((uint32_t)guard.expected);
    serial_text(","); serial_hex((uint32_t)guard.digit);
    serial_text(","); serial_hex((uint32_t)guard.status);
    serial_text(","); serial_hex(object_score);
    serial_text(","); serial_hex(class_margin);
    serial_text(","); serial_hex(guard.passed);
    serial_text(","); serial_hex(guard.rejected);
    serial_text(","); serial_hex(REG(0x0c));
    serial_text(","); serial_hex(decision_cycles);
    serial_text(","); serial_hex(gesture_mode);
    serial_text("\r\n");
}

static void select_mode(unsigned enabled) {
    gesture_mode = enabled != 0;
    REG(0x5c) = gesture_mode;
    guard_expected(&guard, gesture_mode && guard.expected == 0 ? 1 : guard.expected);
    object_score = 0;
    class_margin = 0;
    decision_cycles = 0;
    dump_requested = 0;
    clear_overlay();
    publish();
    serial_text(gesture_mode ? "MODE HAND 1-9\r\n" : "MODE LABEL 0-9\r\n");
}

static void detect(void) {
    int best_score = INT32_MIN;
    int best_cell = 0;
    for (int cell = 0; cell < 16; cell++) {
        int score = result_value((uint32_t)cell * 27u);
        if (score > best_score) { best_score = score; best_cell = cell; }
    }
    object_score = (unsigned)clamp(best_score, 0, 127);
    clear_overlay();
    class_margin = 0;
    if (best_score < (gesture_mode ? GESTURE_EMPTY_SCORE : MODEL_EMPTY_SCORE)) {
        guard_observe(&guard, OBS_EMPTY, -1, 0, 0);
        publish();
        return;
    }
    uint32_t offset = (uint32_t)best_cell * 27u;
    int32_t best_class = INT32_MIN;
    int32_t second_class = INT32_MIN;
    int category = -1;
    unsigned first_class = gesture_mode ? 3u : 12u;
    unsigned class_count = gesture_mode ? 9u : 10u;
    for (unsigned class_index = 0; class_index < class_count; class_index++) {
        int32_t logit = result_value(offset + 5u + first_class + class_index);
        if (logit > best_class) { second_class = best_class; best_class = logit; category = (int)class_index + (gesture_mode ? 1 : 0); }
        else if (logit > second_class) second_class = logit;
    }
    class_margin = (unsigned)(best_class - second_class);
    if (best_score < (gesture_mode ? GESTURE_OBJECT_THRESHOLD : MODEL_OBJECT_THRESHOLD) ||
        class_margin < (gesture_mode ? GESTURE_CLASS_MARGIN : MODEL_CLASS_MARGIN)) {
        guard_observe(&guard, OBS_UNCERTAIN, -1, 0, 0);
        publish();
        return;
    }
    int center_x = ((best_cell % 4) * 16 * 128 + clamp(result_value(offset + 1), 0, 127) * 16) >> 7;
    int center_y = ((best_cell / 4) * 16 * 128 + clamp(result_value(offset + 2), 0, 127) * 16) >> 7;
    int width = clamp(result_value(offset + 3) * 64 / 128, 4, 64);
    int height = clamp(result_value(offset + 4) * 64 / 128, 4, 64);
    int left = clamp(112 + 4 * clamp(center_x - width / 2, 0, 63), 80, 399);
    int right = clamp(112 + 4 * clamp(center_x + width / 2, 0, 63), 80, 399);
    int top = clamp(8 + 4 * clamp(center_y - height / 2, 0, 63), 16, 255);
    int bottom = clamp(8 + 4 * clamp(center_y + height / 2, 0, 63), 16, 255);
    if (right <= left || bottom <= top) {
        guard_observe(&guard, OBS_UNCERTAIN, -1, 0, 0);
        publish();
        return;
    }
    REG(0x20) = (uint32_t)left | (uint32_t)top << 16;
    REG(0x24) = (uint32_t)right | (uint32_t)bottom << 16;
    REG(0x28) = 0x80000000u | (uint32_t)(category + (gesture_mode ? 2 : 12)) | object_score << 8;
    int event = guard_observe(&guard, OBS_VALID, category, center_x, center_y);
    decision_cycles = REG(0x1c) - REG(0x44);
    publish();
    if (event) event_report();
}

int main(void) {
    guard_expected(&guard, 0);
    publish();
    serial_text("VISION50 READY NUMGUARD INT8\r\nMODEL CLASSES=");
    serial_hex(MODEL_CLASS_MASK);
    serial_text("\r\ng HAND 1-9; l LABEL 0-9; 0-9 TARGET; q CLEAR; n INFER; b BARS; f FREEZE; r RESET; d FRAME; ? STATUS\r\n");
    uint32_t last_report = REG(0x1c);
    uint32_t last_result = last_report;
    for (;;) {
        uint32_t status = REG(0x04);
        uint32_t now = REG(0x1c);
        if ((status & 0xe3u) != 0x21u || now - last_result > CLOCK_HZ) {
            if (guard.status != GUARD_FAULT) {
                guard_observe(&guard, OBS_FAULT, -1, 0, 0);
                clear_overlay();
                publish();
            }
        }
        if (status & 0x10u) {
            if ((status & 0xe7u) == 0x25u) detect();
            else { guard_observe(&guard, OBS_FAULT, -1, 0, 0); clear_overlay(); publish(); }
            if (dump_requested && (status & 0xe7u) == 0x25u) dump_frame();
            REG(0x18) = REG(0x18) | 0x10u;
            last_result = now;
        }
        if (REG(0x60) & 1u) { select_mode(!gesture_mode); last_result = now; }
        if (REG(0x40) & 1u) {
            int next = gesture_mode ? guard.expected == 9 ? 1 : guard.expected + 1 : (guard.expected + 1) % 10;
            guard_expected(&guard, next); clear_overlay(); publish();
        }
        if (REG(0x8c) & 1u) {
            uint32_t command = REG(0x88);
            uint32_t control = REG(0x18);
            if (command >= (gesture_mode ? '1' : '0') && command <= '9') { guard_expected(&guard, (int)(command - '0')); clear_overlay(); publish(); }
            if (command == 'g' || command == 'G') { select_mode(1); last_result = now; }
            if (command == 'l' || command == 'L') { select_mode(0); last_result = now; }
            if (command == 'q') { guard.passed = 0; guard.rejected = 0; guard_expected(&guard, guard.expected); clear_overlay(); publish(); }
            if (command == 'c') REG(0x18) = (control | 1u) & ~4u;
            if (command == 'b') REG(0x18) = control ^ 4u;
            if (command == 'f') REG(0x18) = control ^ 2u;
            if (command == 'n') REG(0x18) = control ^ 1u;
            if (command == 'r') REG(0x18) = (control | 8u) & ~2u;
            if (command == 'd') dump_requested = 1;
            if (command == '?') last_report = now - CLOCK_HZ;
        }
        if (now - last_report >= CLOCK_HZ) {
            last_report = now;
            serial_text("NUMGUARD S="); serial_hex(status);
            serial_text(" MODE="); serial_hex(gesture_mode);
            serial_text(" STATE="); serial_hex((uint32_t)guard.status);
            serial_text(" EXP="); serial_hex((uint32_t)guard.expected);
            serial_text(" OK="); serial_hex(guard.passed);
            serial_text(" BAD="); serial_hex(guard.rejected);
            serial_text(" NN="); serial_hex(REG(0x30));
            serial_text(" NPU="); serial_hex(REG(0x0c));
            serial_text(" DEC="); serial_hex(decision_cycles);
            serial_text("\r\n");
        }
    }
}
