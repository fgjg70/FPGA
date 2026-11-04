#include <stdint.h>
#include "model_info.h"
#include "numeric_guard.h"
#include "object_decode.h"
#include "platform_clock.h"
#include "servo_control.h"
#include "sorter.h"

#define REG(offset) (*(volatile uint32_t *)(0xa1000000u + (offset)))
#include "runtime_coremark.h"

enum recognition_mode { MODE_CAPS, MODE_GESTURE, MODE_COREMARK, MODE_COUNT };
static numeric_guard guard;
static unsigned application_mode;
static unsigned mode_ready;
static unsigned object_score;
static unsigned object_count;
static unsigned class_margin;
static unsigned processed_frames;
static unsigned empty_frames;
static unsigned object_state;
static unsigned dump_requested;
static uint32_t decision_cycles;
static int32_t outputs[432];
static servo_parser servo_input;
static sorter_state sorter;
static unsigned automatic_requested;
static uint32_t last_result;

static void service_sorter(void) {
    uint32_t now = REG(0x1c);
    if (sorter.mode == SORTER_CAPS && ((REG(0x04) & 0xe3u) != 0x21u || now - last_result > CLOCK_HZ))
        sorter_select(&sorter, SORTER_OFF, now);
    sorter_tick(&sorter, now);
    if (!sorter.dirty) return;
    for (unsigned index = 0; index < 7; index++) if (sorter.dirty & (1u << index)) REG(0xe0 + index * 4u) = sorter.pulse[index];
    REG(0xd0) = sorter.enabled;
    sorter.dirty = 0;
}

static void start_benchmark(void) {
    automatic_requested = 0;
    sorter_select(&sorter, SORTER_OFF, REG(0x1c));
    service_sorter();
    application_mode = MODE_COREMARK;
    mode_ready = 0;
    dump_requested = 0;
    run_coremark();
}

static void serial_text(const char *text) {
    while (*text) {
        while (REG(0x84) & 1u) service_sorter();
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

static void diagnose_memory(void) {
    uint32_t status = REG(0x7c);
    serial_text("DDR3 STATUS="); serial_hex(status); serial_text("\r\n");
    if ((status & 15u) != 15u || (status & 0x50u)) {
        serial_text("DDR3 NOT READY; PHY CALIBRATION AND MEMORY BIST REQUIRED\r\n");
        return;
    }
    volatile uint32_t *cache_control = (volatile uint32_t *)0xa1000100u;
    volatile uint32_t *memory = (volatile uint32_t *)0xc0000000u;
    *cache_control = 2;
    unsigned errors = 0;
    for (unsigned phase = 0; phase < 4; phase++) {
        for (unsigned index = 0; index < 512; index++) memory[index] = (0xa5963c69u ^ (index * 4u)) ^ (phase & 1u ? 0xffffffffu : 0u);
        for (unsigned index = 0; index < 512; index++) {
            uint32_t expected = (0xa5963c69u ^ (index * 4u)) ^ (phase & 1u ? 0xffffffffu : 0u);
            if (memory[index] != expected) errors++;
        }
    }
    *cache_control = 3;
    serial_text(errors ? "DDR3 CPU TEST FAIL errors=" : "DDR3 CPU TEST PASS errors=");
    serial_hex(errors); serial_text("\r\nCACHE HITS=");
    serial_hex(*(volatile uint32_t *)0xa1000104u);
    serial_text(" MISSES="); serial_hex(*(volatile uint32_t *)0xa1000108u); serial_text("\r\n");
}

static int32_t result_value(uint32_t index) {
    REG(0x10) = index;
    __asm__ volatile ("nop\nnop" ::: "memory");
    return (int32_t)REG(0x14);
}

static void dump_frame(void) {
    const char *digits = "0123456789ABCDEF";
    uint32_t checksum = 0xffffffffu;
    unsigned channels = application_mode == MODE_GESTURE ? 1u : 3u;
    serial_text(channels == 1 ? "Q7FRAME BEGIN\r\n" : "RGBQ7FRAME BEGIN\r\n");
    for (unsigned index = 0; index < channels * 4096u; index++) {
        REG(0x54) = index;
        __asm__ volatile ("nop\nnop" ::: "memory");
        unsigned value = REG(0x58) & 255u;
        char text[3] = {digits[value >> 4], digits[value & 15u], 0};
        serial_text(text);
        checksum ^= value;
        for (unsigned bit = 0; bit < 8; bit++) checksum = (checksum >> 1) ^ (0xedb88320u & (0u - (checksum & 1u)));
        if ((index & 63u) == 63u) serial_text("\r\n");
    }
    serial_text(channels == 1 ? "Q7FRAME END " : "RGBQ7FRAME END ");
    serial_hex(~checksum);
    serial_text("\r\n");
    dump_requested = 0;
}

static void clear_overlay(void) {
    REG(0x28) = 0;
    for (unsigned index = 0; index < 3; index++) REG(0xa8 + index * 16) = 0;
    object_count = 0;
}

static void publish(void) {
    unsigned gesture = application_mode == MODE_GESTURE;
    REG(0x34) = (gesture ? (uint32_t)guard.status : object_state) |
                (gesture ? (uint32_t)guard.expected << 4 | (uint32_t)(guard.digit < 0 ? 15 : guard.digit) << 8 | guard.stable << 12 | guard.armed << 15 : 0) |
                object_score << 16 | application_mode << 23 | (mode_ready ? 0u : 1u << 25) | object_count << 28;
    REG(0x38) = gesture ? guard.passed : processed_frames;
    REG(0x3c) = gesture ? guard.rejected : empty_frames;
    REG(0x2c) = 1;
}

static void select_mode(unsigned mode) {
    if (mode >= MODE_COUNT || mode == MODE_COREMARK) return;
    application_mode = mode;
    mode_ready = (REG(0x64) & (1u << mode)) != 0;
    automatic_requested = 1;
    sorter_select(&sorter, mode == MODE_CAPS && mode_ready ? SORTER_CAPS : SORTER_OFF, REG(0x1c));
    service_sorter();
    REG(0x5c) = mode;
    REG(0x18) = (REG(0x18) | 1u) & ~4u;
    guard_expected(&guard, guard.expected >= 1 && guard.expected <= GESTURE_DIGIT_MAX ? guard.expected : 1);
    object_state = mode_ready ? GUARD_WAIT : GUARD_FAULT;
    object_score = 0;
    class_margin = 0;
    decision_cycles = 0;
    dump_requested = 0;
    if (!mode_ready) guard_observe(&guard, OBS_FAULT, -1, 0, 0);
    clear_overlay();
    publish();
    if (mode == MODE_GESTURE) {
        serial_text(GESTURE_DIGIT_MAX == 5 ? "MODE HAND 1-5\r\n" : (GESTURE_DIGIT_MAX == 10 ? "MODE HAND 1-10\r\n" : "MODE HAND 1-9\r\n"));
        if (GESTURE_DIGIT_MAX != 10) serial_text("EXPERIMENTAL LEGACY BANK; BOARD ACCURACY UNVERIFIED\r\n");
    }
    else if (mode == MODE_CAPS) serial_text("MODE BOTTLE CAPS: FEED=1 EVERY 5S; GREEN=2 YELLOW=3 RED=4\r\n");
    if (!mode_ready) serial_text("MODEL NOT LOADED\r\n");
}

static void write_box(unsigned index, int left, int top, int right, int bottom, unsigned category, unsigned score) {
    unsigned first = index ? 0xa0 + (index - 1) * 16 : 0x20;
    REG(first) = (uint32_t)left | (uint32_t)top << 16;
    REG(first + 4) = (uint32_t)right | (uint32_t)bottom << 16;
    REG(first + 8) = 0x80000000u | category | (unsigned)object_clip((int)score, 0, 127) << 8;
}

static void detect_objects(void) {
    object_detection detected[4];
    clear_overlay();
    object_count = object_decode(outputs, object_thresholds[application_mode], object_margins[application_mode], detected);
    processed_frames++;
    if (!object_count) empty_frames++;
    object_state = object_count ? GUARD_MATCH : GUARD_EMPTY;
    object_score = object_count ? (unsigned)object_clip(detected[0].score, 0, 127) : 0;
    sorter_observe(&sorter, object_count, object_count ? (unsigned)detected[0].category : 0u, REG(0x44), REG(0x1c));
    for (unsigned index = 0; index < object_count; index++) {
        object_detection *item = &detected[index];
        write_box(index, object_clip(80 + item->left * 5, 80, 399), object_clip(16 + (item->top - 8) * 5, 16, 255),
                  object_clip(80 + item->right * 5, 80, 399), object_clip(16 + (item->bottom - 8) * 5, 16, 255),
                  22u + (unsigned)item->category, (unsigned)item->score);
    }
}

static void detect_gesture(void) {
    int best_cell = 0;
    for (int cell = 1; cell < 16; cell++) if (outputs[cell * 27] > outputs[best_cell * 27]) best_cell = cell;
    int32_t *values = outputs + best_cell * 27;
    object_score = (unsigned)object_clip(values[0], 0, 127);
    clear_overlay();
    class_margin = 0;
    if (values[0] < GESTURE_EMPTY_SCORE) {
        guard_observe(&guard, OBS_EMPTY, -1, 0, 0);
        return;
    }
    int best_class = INT32_MIN;
    int second_class = INT32_MIN;
    int category = 0;
    for (unsigned index = 0; index < GESTURE_DIGIT_MAX; index++) {
        int score = values[5 + gesture_class_indices[index]];
        if (score > best_class) { second_class = best_class; best_class = score; category = (int)index + 1; }
        else if (score > second_class) second_class = score;
    }
    class_margin = (unsigned)object_clip(best_class - second_class, 0, 127);
    if (values[0] < GESTURE_OBJECT_THRESHOLD || class_margin < GESTURE_CLASS_MARGIN) {
        guard_observe(&guard, OBS_UNCERTAIN, -1, 0, 0);
        return;
    }
    int center_x = best_cell % 4 * 16 + object_clip(values[1], 0, 127) / 8;
    int center_y = best_cell / 4 * 16 + object_clip(values[2], 0, 127) / 8;
    int width = object_clip(object_clip(values[3], 0, 128) / 2, 4, 64);
    int height = object_clip(object_clip(values[4], 0, 128) / 2, 4, 64);
    write_box(0, object_clip(112 + 4 * object_clip(center_x - width / 2, 0, 63), 80, 399), object_clip(8 + 4 * object_clip(center_y - height / 2, 0, 63), 16, 255),
              object_clip(112 + 4 * object_clip(center_x + width / 2, 0, 63), 80, 399), object_clip(8 + 4 * object_clip(center_y + height / 2, 0, 63), 16, 255),
              gesture_class_indices[category - 1], object_score);
    object_count = 1;
    if (guard_observe(&guard, OBS_VALID, category, center_x, center_y)) {
        serial_text("GESTURE EVENT "); serial_hex((uint32_t)category); serial_text("\r\n");
    }
}

int main(void) {
    serial_text("VISION SOC READY\r\nCPU_HZ="); serial_hex(CPU_CLOCK_HZ); serial_text("\r\n");
    guard_expected(&guard, 1);
    select_mode((REG(0x64) & 1u) ? MODE_CAPS : MODE_GESTURE);
    serial_text("SW2 RESET; SW4 COREMARK; SW5 CAPS; SW6 HAND; k BENCH; p CAPS; g HAND; d FRAME; ? STATUS\r\n");
    uint32_t last_report = REG(0x1c);
    last_result = last_report;
    for (;;) {
        uint32_t status = REG(0x04);
        uint32_t now = REG(0x1c);
        if (sorter.mode == SORTER_CAPS && ((status & 0xe3u) != 0x21u || now - last_result > CLOCK_HZ))
            sorter_select(&sorter, SORTER_OFF, now);
        service_sorter();
        if (application_mode < MODE_COREMARK && mode_ready && ((status & 0xe3u) != 0x21u || now - last_result > CLOCK_HZ) &&
            (object_state != GUARD_FAULT || guard.status != GUARD_FAULT)) {
            object_state = GUARD_FAULT;
            guard_observe(&guard, OBS_FAULT, -1, 0, 0);
            clear_overlay();
            publish();
        }
        if (application_mode < MODE_COREMARK && mode_ready && (status & 0x10u)) {
            if ((status & 0xe7u) == 0x25u) {
                for (unsigned index = 0; index < 432; index++) outputs[index] = result_value(index);
                if (application_mode == MODE_GESTURE) detect_gesture();
                else {
                    if (automatic_requested && sorter.mode == SORTER_OFF) sorter_select(&sorter, SORTER_CAPS, now);
                    detect_objects();
                }
                decision_cycles = REG(0x1c) - REG(0x44);
                publish();
                if (dump_requested) dump_frame();
            } else {
                sorter_select(&sorter, SORTER_OFF, now);
                service_sorter();
                object_state = GUARD_FAULT;
                guard_observe(&guard, OBS_FAULT, -1, 0, 0);
                clear_overlay();
                publish();
            }
            REG(0x18) = REG(0x18) | 0x10u;
            last_result = now;
        }
        unsigned keys = REG(0x60);
        if (keys) REG(0x60) = keys;
        if (keys & 1u) {
            start_benchmark();
        } else if (keys & 2u) { select_mode(MODE_CAPS); last_result = now; }
        else if (keys & 4u) { select_mode(MODE_GESTURE); last_result = now; }
        if ((REG(0x40) & 1u) && application_mode == MODE_GESTURE) {
            guard_expected(&guard, guard.expected == GESTURE_DIGIT_MAX ? 1 : guard.expected + 1);
            clear_overlay();
            publish();
        }
        if (REG(0x8c) & 1u) {
            uint32_t command = REG(0x88);
            unsigned servo_number = 0;
            unsigned servo_pulse_us = 0;
            int servo_result = servo_receive(&servo_input, command, &servo_number, &servo_pulse_us);
            if (servo_result == 2) {
                automatic_requested = 0;
                if (sorter.mode != SORTER_OFF) {
                    sorter_select(&sorter, SORTER_OFF, now);
                    service_sorter();
                }
                if (!servo_number) REG(0xd0) = 0;
                else if (!servo_pulse_us) REG(0xd0) = REG(0xd0) & ~(1u << (servo_number - 1));
                else {
                    REG(0xe0 + (servo_number - 1) * 4) = servo_pulse_us;
                    REG(0xd0) = REG(0xd0) | (1u << (servo_number - 1));
                }
                serial_text("SERVO OK\r\n");
            } else if (servo_result < 0) serial_text("SERVO ERROR: s1=1000..2000, s1=0, s0=0\r\n");
            if (!servo_result) {
                uint32_t control = REG(0x18);
                if (mode_ready && application_mode == MODE_GESTURE && command >= '1' && command <= '0' + GESTURE_DIGIT_MAX && command <= '9') { guard_expected(&guard, (int)(command - '0')); clear_overlay(); publish(); }
                if (mode_ready && application_mode == MODE_GESTURE && GESTURE_DIGIT_MAX == 10 && command == '0') { guard_expected(&guard, 10); clear_overlay(); publish(); }
                if (command == 'g' || command == 'G') { select_mode(MODE_GESTURE); last_result = now; }
                if (command == 'p' || command == 'P') { select_mode(MODE_CAPS); last_result = now; }
                if (command == 'k' || command == 'K') start_benchmark();
                if (command == 'm' || command == 'M') { select_mode(application_mode == MODE_CAPS ? MODE_GESTURE : MODE_CAPS); last_result = now; }
                if (command == 'q') { guard.passed = 0; guard.rejected = 0; processed_frames = 0; empty_frames = 0; clear_overlay(); publish(); }
                if (command == 'c' && application_mode != MODE_COREMARK) REG(0x18) = (control | 1u) & ~4u;
                if (command == 'b') REG(0x18) = control ^ 4u;
                if (command == 'f') REG(0x18) = control ^ 2u;
                if (command == 'n' && application_mode != MODE_COREMARK) REG(0x18) = control ^ 1u;
                if (command == 'r') REG(0x18) = (control | 8u) & ~2u;
                if (command == 'd' && mode_ready && application_mode < MODE_COREMARK) dump_requested = 1;
                if (command == '?') last_report = now - CLOCK_HZ;
                if (command == 't') diagnose_memory();
            }
        }
        if (now - last_report >= CLOCK_HZ) {
            last_report = now;
            serial_text("VISION S="); serial_hex(status);
            serial_text(" MODE="); serial_hex(application_mode);
            serial_text(" READY="); serial_hex(mode_ready);
            serial_text(" COUNT="); serial_hex(object_count);
            serial_text(" NN="); serial_hex(REG(0x30));
            serial_text(" NPU="); serial_hex(REG(0x0c));
            serial_text(" DEC="); serial_hex(decision_cycles);
            serial_text(" PWM="); serial_hex(REG(0xd0));
            serial_text(" FEED="); serial_hex(sorter.drops);
            serial_text("\r\n");
        }
    }
}
