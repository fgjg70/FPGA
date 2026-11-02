#include <stdint.h>
#include "model_info.h"

#define REG(offset) (*(volatile uint32_t *)(0xa1000000u + (offset)))
#include "platform_clock.h"

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

static int clamp(int value, int lower, int upper) {
    if (value < lower) return lower;
    if (value > upper) return upper;
    return value;
}

static void clear_overlay(void) {
    REG(0x28) = 0;
    REG(0x2c) = 1;
}

static int detect(void) {
    int best_score = MODEL_OBJECT_THRESHOLD - 1;
    int best_cell = -1;
    int best_label = 0;
    for (int cell = 0; cell < 16; cell++) {
        int score = result_value((uint32_t)cell * 27u);
        if (score <= best_score) continue;
        int32_t class_score = INT32_MIN;
        int category = -1;
        for (int label_index = 0; label_index < 22; label_index++) {
            if (!(MODEL_CLASS_MASK & (1u << label_index))) continue;
            int32_t logit = result_value((uint32_t)cell * 27u + 5u + (uint32_t)label_index);
            if (logit > class_score) { class_score = logit; category = label_index; }
        }
        if (category >= 0) { best_score = score; best_cell = cell; best_label = category; }
    }
    if (best_cell < 0) { clear_overlay(); return 0; }
    uint32_t offset = (uint32_t)best_cell * 27u;
    int center_x = ((best_cell % 4) * 16 * 128 + clamp(result_value(offset + 1), 0, 127) * 16) >> 7;
    int center_y = ((best_cell / 4) * 16 * 128 + clamp(result_value(offset + 2), 0, 127) * 16) >> 7;
    int width = clamp(result_value(offset + 3) * 64 / 128, 4, 64);
    int height = clamp(result_value(offset + 4) * 64 / 128, 4, 64);
    int left = clamp(112 + 4 * clamp(center_x - width / 2, 0, 63), 80, 399);
    int right = clamp(112 + 4 * clamp(center_x + width / 2, 0, 63), 80, 399);
    int top = clamp(8 + 4 * clamp(center_y - height / 2, 0, 63), 16, 255);
    int bottom = clamp(8 + 4 * clamp(center_y + height / 2, 0, 63), 16, 255);
    if (right <= left || bottom <= top) { clear_overlay(); return 0; }
    REG(0x20) = (uint32_t)left | (uint32_t)top << 16;
    REG(0x24) = (uint32_t)right | (uint32_t)bottom << 16;
    REG(0x28) = 0x80000000u | (uint32_t)best_label | ((uint32_t)clamp(best_score, 0, 127) << 8);
    REG(0x2c) = 1;
    return 1;
}

int main(void) {
    serial_text("VISION50 READY MICROYOLO64 INT8\r\nMODEL CLASSES=");
    serial_hex(MODEL_CLASS_MASK);
    serial_text("\r\n");
    uint32_t last_report = REG(0x1c);
    uint32_t last_result = last_report;
    int detected = 0;
    for (;;) {
        uint32_t status = REG(0x04);
        uint32_t now = REG(0x1c);
        if (status & 0x10u) {
            if ((status & 0xa3u) == 0x21u) detected = detect();
            else { clear_overlay(); detected = 0; }
            REG(0x18) = REG(0x18) | 0x10u;
            last_result = now;
        }
        if (!(status & 0x20u) || (status & 0x82u) || (!(status & 0x40u) && now - last_result > CLOCK_HZ)) {
            if (detected) { clear_overlay(); detected = 0; }
        }
        if (REG(0x8c) & 1u) {
            uint32_t command = REG(0x88);
            uint32_t control = REG(0x18);
            if (command == 'c') REG(0x18) = (control | 1u) & ~4u;
            if (command == 'b') REG(0x18) = control ^ 4u;
            if (command == 'f') REG(0x18) = control ^ 2u;
            if (command == 'n') REG(0x18) = control ^ 1u;
            if (command == 'r') REG(0x18) = (control | 8u) & ~2u;
            if (command == '?') last_report = now - CLOCK_HZ;
        }
        if (now - last_report >= CLOCK_HZ) {
            last_report = now;
            serial_text("VISION S="); serial_hex(status);
            serial_text(" FR="); serial_hex(REG(0x08));
            serial_text(" NN="); serial_hex(REG(0x30));
            serial_text(" CYC="); serial_hex(REG(0x0c));
            serial_text(" DET="); serial_hex((uint32_t)detected);
            serial_text("\r\n");
        }
    }
}
