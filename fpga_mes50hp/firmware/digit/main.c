#include <stdint.h>
#include "digit_model.h"
#include "platform.h"

#define GPIO REGISTER(0xA0000000u)
#define UART_TX REGISTER(0xA0000010u)
#define UART_BUSY REGISTER(0xA0000014u)
#define UART_RX REGISTER(0xA0000018u)
#define UART_READY REGISTER(0xA000001Cu)
#define UART_ERRORS REGISTER(0xA00000B0u)
#define UART_OVERRUN REGISTER(0xA00000B4u)
#define UART_FRAMING REGISTER(0xA00000B8u)
#define UART_CONTROL REGISTER(0xA00000BCu)
#define GEMM_CTRL REGISTER(0xA0000040u)
#define GEMM_STATUS REGISTER(0xA0000044u)
#define GEMM_M REGISTER(0xA0000048u)
#define GEMM_K REGISTER(0xA000004Cu)
#define GEMM_N REGISTER(0xA0000050u)
#define GEMM_CYCLES REGISTER(0xA0000054u)
#define GEMM_C_INDEX REGISTER(0xA0000068u)
#define GEMM_C_DATA REGISTER(0xA000006Cu)
#define GEMM_ID REGISTER(0xA0000070u)
#define GEMM_A ((volatile uint32_t *)0xA0000400u)
#define GEMM_B ((volatile uint32_t *)0xA0000500u)

static uint8_t packet[256] __attribute__((aligned(4)));
static int8_t image[256] __attribute__((aligned(4)));
static int8_t hidden[32] __attribute__((aligned(4)));
static int32_t software_logits[10], hardware_logits[10];
static configuration_t configuration;
static uint8_t entered[4];
static uint32_t entered_count, door, recognized, image_valid, candidate_valid, predicted;
static uint32_t unlock_time, accelerator_cycles, software_cycles, hardware_cycles;
static uint32_t candidate_token, token_counter, interaction_epoch, busy;
static uint32_t display_dirty, gpio_cached, request_save, request_infer, request_restore;
static uint32_t restore_started, restore_holding, restore_fired;
static uint32_t software_valid, hardware_valid;
static uint16_t outgoing_crc;

static void lock_door(void) {
    door = 0;
    entered_count = 0;
    candidate_valid = 0;
    recognized = 0;
    interaction_epoch++;
    display_dirty = 1;
}

static void cancel_entry(void) {
    if (candidate_valid) candidate_valid = 0;
    else if (entered_count) entered_count--;
    interaction_epoch++;
    display_dirty = 1;
}

static void confirm_digit(void) {
    if (!candidate_valid) return;
    entered[entered_count++] = (uint8_t)predicted;
    candidate_valid = 0;
    interaction_epoch++;
    if (entered_count == 4) {
        uint32_t matches = 1;
        for (uint32_t index = 0; index < 4; index++) matches &= entered[index] == configuration.pin[index];
        door = matches ? 1 : 2;
        unlock_time = CYCLE;
        entered_count = 0;
    }
    display_dirty = 1;
}

static void clear_image(void) {
    entered_count = 0;
    candidate_valid = 0;
    image_valid = 0;
    recognized = 0;
    predicted = 255;
    interaction_epoch++;
    display_dirty = 1;
}

void app_service(void) {
    uint32_t events = KEY_EVENTS;
    if (events) {
        KEY_EVENTS = events;
        if (events & 1u) lock_door();
        else {
            if (events & 2u) cancel_entry();
            if (events & 4u) confirm_digit();
            if (events & 8u) {
                configuration.mode = (configuration.mode + 1) % 3;
                candidate_valid = 0;
                interaction_epoch++;
                request_save = 1;
                display_dirty = 1;
            }
            if (events & 16u) request_infer = image_valid;
            if (events & 32u) clear_image();
        }
    }
    if (KEY_LEVELS & 64u) {
        if (!restore_holding) { restore_started = CYCLE; restore_holding = 1; }
        else if (!restore_fired && (uint32_t)(CYCLE - restore_started) >= 100000000u) {
            request_restore = 1;
            restore_fired = 1;
        }
    } else {
        restore_holding = 0;
        restore_fired = 0;
    }
    if ((door & 1u) && (uint32_t)(CYCLE - unlock_time) >= configuration.unlock_ms * 50000u) {
        door = 0;
        display_dirty = 1;
    }
    uint32_t progress = entered_count ? ((1u << entered_count) - 1u) : 0;
    uint32_t gpio = recognized | ((door & 1u) << 1) | ((door & 2u) << 1) | (progress << 4) | (busy << 7);
    if (gpio != gpio_cached) { GPIO = gpio; gpio_cached = gpio; }
}

static uint32_t time_bcd(uint32_t cycles) {
    uint32_t microseconds = cycles / 50u;
    if (microseconds > 999999u) microseconds = 999999u;
    uint32_t result = 0;
    for (uint32_t digit_index = 0; digit_index < 6; digit_index++) {
        result |= (microseconds % 10) << (digit_index * 4);
        microseconds /= 10;
    }
    return result;
}

static void publish_display(void) {
    if (!display_dirty || (DISPLAY_COMMIT & 1u)) return;
    uint32_t flags = platform_status();
    DISPLAY_STATE = door | (entered_count << 2) | (candidate_valid << 5) | ((predicted & 15u) << 8) |
                    (configuration.mode << 12) | (busy << 14) | (image_valid << 15) |
                    ((flags & 2u) << 15) | ((flags & 8u) << 14) | ((flags & 4u) << 16) |
                    ((flags & 1u) << 19) | (request_save << 20);
    DISPLAY_SOFTWARE = time_bcd(software_cycles);
    DISPLAY_HARDWARE = time_bcd(hardware_cycles);
    const uint32_t *words = (const uint32_t *)image;
    for (uint32_t index = 0; index < 64; index++) DISPLAY_IMAGE[index] = image_valid ? words[index] : 0;
    DISPLAY_COMMIT = 1;
    display_dirty = 0;
}

static void put_byte(uint8_t value) {
    while (UART_BUSY & 1u) app_service();
    UART_TX = value;
}

static int get_byte(uint32_t started, uint32_t timeout) {
    while (!(UART_READY & 1u)) {
        app_service();
        if ((uint32_t)(CYCLE - started) >= timeout) return -1;
    }
    return (int)(UART_RX & 255u);
}

static void send_checked(uint8_t value) {
    outgoing_crc = crc_update(outgoing_crc, value);
    put_byte(value);
}

static void response_begin(uint8_t command, uint8_t sequence, uint16_t length) {
    put_byte('P'); put_byte('G');
    outgoing_crc = 0xFFFFu;
    send_checked(command | 0x80u); send_checked(sequence);
    send_checked((uint8_t)length); send_checked((uint8_t)(length >> 8));
}

static void response_end(void) {
    uint16_t checksum = outgoing_crc;
    put_byte((uint8_t)checksum); put_byte((uint8_t)(checksum >> 8));
}

static void send_word(uint32_t value) {
    for (uint32_t byte_index = 0; byte_index < 4; byte_index++) {
        send_checked((uint8_t)value);
        value >>= 8;
    }
}

static void status_response(uint8_t command, uint8_t sequence, uint8_t status) {
    response_begin(command, sequence, 1); send_checked(status); response_end();
}

static int32_t dot_software(const int8_t *left, const int8_t *right, uint32_t count) {
    int32_t sum = 0;
    for (uint32_t index = 0; index < count; index++) sum += (int32_t)left[index] * right[index];
    return sum;
}

static void upload(volatile uint32_t *destination, const int8_t *source, uint32_t count) {
    const uint32_t *words = (const uint32_t *)source;
    for (uint32_t index = 0; index < count / 4; index++) destination[index] = words[index];
}

static int dot_hardware(const int8_t *weights, uint32_t count, int32_t *sum) {
    upload(GEMM_B, weights, count);
    GEMM_CTRL = 1;
    uint32_t started = CYCLE;
    while (1) {
        uint32_t status = GEMM_STATUS;
        if ((status & 4u) || (uint32_t)(CYCLE - started) > 1000000u) { GEMM_CTRL = 4; return -1; }
        if (status & 2u) break;
        app_service();
    }
    *sum = (int32_t)GEMM_C_DATA;
    accelerator_cycles += GEMM_CYCLES;
    return 0;
}

static int infer(uint32_t use_hardware, int32_t *logits) {
    if (use_hardware) {
        GEMM_M = 1; GEMM_N = 1; GEMM_K = 256; GEMM_C_INDEX = 0;
        upload(GEMM_A, image, 256);
    }
    for (uint32_t neuron = 0; neuron < 32; neuron++) {
        int32_t sum;
        const int8_t *weights = digit_w1 + neuron * 256;
        if (use_hardware) {
            if (dot_hardware(weights, 256, &sum)) return -1;
        } else sum = dot_software(image, weights, 256);
        sum = (sum + digit_b1[neuron]) >> DIGIT_HIDDEN_SHIFT;
        hidden[neuron] = sum < 0 ? 0 : sum > 127 ? 127 : (int8_t)sum;
    }
    if (use_hardware) { GEMM_K = 32; upload(GEMM_A, hidden, 32); }
    for (uint32_t neuron = 0; neuron < 10; neuron++) {
        int32_t sum;
        const int8_t *weights = digit_w2 + neuron * 32;
        if (use_hardware) {
            if (dot_hardware(weights, 32, &sum)) return -1;
        } else sum = dot_software(hidden, weights, 32);
        logits[neuron] = sum + digit_b2[neuron];
    }
    return 0;
}

static int recognize(uint32_t mode) {
    uint32_t epoch = interaction_epoch;
    candidate_valid = 0;
    busy = 1;
    display_dirty = 1;
    software_cycles = 0; hardware_cycles = 0; accelerator_cycles = 0;
    software_valid = 0; hardware_valid = 0;
    app_service();
    publish_display();
    if (mode != 0) {
        uint32_t started = CYCLE;
        infer(0, software_logits);
        software_cycles = CYCLE - started;
        software_valid = 1;
    }
    if (mode != 1) {
        uint32_t started = CYCLE;
        if (GEMM_ID != 0x474D0101u || infer(1, hardware_logits)) {
            busy = 0;
            display_dirty = 1;
            app_service();
            return 3;
        }
        hardware_cycles = CYCLE - started;
        hardware_valid = 1;
    }
    uint32_t mismatch = 0;
    if (mode == 2)
        for (uint32_t index = 0; index < 10; index++) mismatch += software_logits[index] != hardware_logits[index];
    int32_t *logits = mode == 1 ? software_logits : hardware_logits;
    predicted = 0;
    for (uint32_t index = 1; index < 10; index++) if (logits[index] > logits[predicted]) predicted = index;
    app_service();
    if (++token_counter == 0) token_counter = 1;
    candidate_token = token_counter;
    candidate_valid = !mismatch && epoch == interaction_epoch && image_valid;
    recognized = !mismatch;
    busy = 0;
    display_dirty = 1;
    app_service();
    return mismatch ? 4 : 0;
}

static void defaults(void) {
    for (uint32_t index = 0; index < 4; index++) configuration.pin[index] = (uint8_t)(index + 1);
    configuration.mode = 0;
    configuration.unlock_ms = 5000;
    lock_door();
}

static uint32_t packet_word(void) {
    return packet[0] | ((uint32_t)packet[1] << 8) | ((uint32_t)packet[2] << 16) | ((uint32_t)packet[3] << 24);
}

static void send_status(uint8_t command, uint8_t sequence) {
    uint8_t snapshot[8];
    uint32_t elapsed_ms = (uint32_t)(CYCLE - unlock_time) / 50000u;
    uint32_t remaining = (door & 1u) && elapsed_ms < configuration.unlock_ms ? configuration.unlock_ms - elapsed_ms : 0;
    uint32_t token = candidate_valid ? candidate_token : 0;
    snapshot[0] = 0; snapshot[1] = (uint8_t)door; snapshot[2] = (uint8_t)entered_count;
    snapshot[3] = (uint8_t)candidate_valid; snapshot[4] = (uint8_t)predicted;
    snapshot[5] = (uint8_t)configuration.mode;
    snapshot[6] = (uint8_t)(platform_status() | (request_save << 4) | (image_valid << 5));
    snapshot[7] = (uint8_t)busy;
    response_begin(command, sequence, 40);
    for (uint32_t index = 0; index < 8; index++) send_checked(snapshot[index]);
    send_word(remaining); send_word(token); send_word(software_cycles); send_word(hardware_cycles);
    send_word(accelerator_cycles); send_word(UART_OVERRUN); send_word(UART_FRAMING); send_word(configuration.generation);
    response_end();
}

static void process(uint8_t command, uint8_t sequence, uint16_t length) {
    app_service();
    if (command == 1 && length == 0) {
        response_begin(command, sequence, 10); send_checked(0); send_checked(2);
        send_word(50000000u); send_word(GEMM_ID); response_end();
        return;
    }
    if (command == 7 && length == 0) { send_status(command, sequence); return; }
    if (command == 15 && length == 0) {
        response_begin(command, sequence, 84);
        send_checked(0); send_checked((uint8_t)software_valid); send_checked((uint8_t)hardware_valid); send_checked(0);
        for (uint32_t index = 0; index < 10; index++) send_word((uint32_t)software_logits[index]);
        for (uint32_t index = 0; index < 10; index++) send_word((uint32_t)hardware_logits[index]);
        response_end(); return;
    }
    if ((command == 5 || command == 9 || command == 11) && length == 0) {
        if (command == 5) lock_door();
        else if (command == 9) cancel_entry();
        else clear_image();
        app_service(); status_response(command, sequence, 0); return;
    }
    if (command == 8 && length == 4) {
        if (!candidate_valid || packet_word() != candidate_token) { status_response(command, sequence, 6); return; }
        confirm_digit(); app_service(); status_response(command, sequence, 0); return;
    }
    if ((command == 6 && length == 4) || (command == 10 && length == 1) ||
        (command == 12 && length == 4) || (command == 14 && length == 4)) {
        if (command == 6) {
            for (uint32_t index = 0; index < 4; index++)
                if (packet[index] > 9) { status_response(command, sequence, 1); return; }
            for (uint32_t index = 0; index < 4; index++) configuration.pin[index] = packet[index];
            lock_door();
        } else if (command == 10) {
            if (packet[0] > 2) { status_response(command, sequence, 1); return; }
            if (configuration.mode == packet[0]) { status_response(command, sequence, 0); return; }
            configuration.mode = packet[0];
            candidate_valid = 0; interaction_epoch++;
        } else if (command == 12) {
            if (packet[0] != 'R' || packet[1] != 'S' || packet[2] != 'T' || packet[3] != '!') {
                status_response(command, sequence, 1); return;
            }
            defaults();
        } else {
            uint32_t timeout = packet_word();
            if (timeout < 1000 || timeout > 30000) { status_response(command, sequence, 1); return; }
            configuration.unlock_ms = timeout;
        }
        request_save = 0;
        uint8_t status = platform_save(&configuration) ? 8 : 0;
        display_dirty = 1; app_service();
        status_response(command, sequence, status); return;
    }
    uint32_t operation = command & 15u;
    if ((command != operation && command != operation + 16) || operation < 2 || operation > 4 || length != 256) {
        status_response(command, sequence, 2); return;
    }
    uint32_t ink = 0;
    for (uint32_t index = 0; index < 256; index++) {
        if (packet[index] > 127) { status_response(command, sequence, 1); return; }
        ink += packet[index];
    }
    candidate_valid = 0;
    if (ink < 128) { clear_image(); status_response(command, sequence, 5); return; }
    for (uint32_t index = 0; index < 256; index++) image[index] = (int8_t)packet[index];
    image_valid = 1;
    uint32_t mode = operation == 2 ? 1 : operation == 3 ? 0 : 2;
    int status = recognize(mode);
    if (status == 3) { status_response(command, sequence, 3); return; }
    uint32_t mismatch = 0;
    if (mode == 2) for (uint32_t index = 0; index < 10; index++) mismatch += software_logits[index] != hardware_logits[index];
    response_begin(command, sequence, (uint16_t)(command & 16u ? 24 : 64));
    send_checked((uint8_t)status); send_checked((uint8_t)predicted); send_checked((uint8_t)door); send_checked((uint8_t)entered_count);
    send_word(software_cycles); send_word(hardware_cycles); send_word(accelerator_cycles); send_word(mismatch);
    if (!(command & 16u)) {
        int32_t *logits = mode == 1 ? software_logits : hardware_logits;
        for (uint32_t index = 0; index < 10; index++) send_word((uint32_t)logits[index]);
    }
    send_word(candidate_valid ? candidate_token : 0);
    response_end();
}

static void background_work(void) {
    if (request_restore) { request_restore = 0; defaults(); request_save = 1; }
    if (request_save) {
        request_save = 0;
        platform_save(&configuration);
        display_dirty = 1;
    }
    if (request_infer) {
        request_infer = 0;
        if (image_valid) recognize(configuration.mode);
    }
    publish_display();
}

int main(void) {
    predicted = 255;
    GPIO = 0;
    defaults();
    platform_initialize(&configuration);
    lock_door();
    while (1) {
        app_service();
        if (!(UART_READY & 1u)) background_work();
        uint32_t started = CYCLE;
        int first = get_byte(started, 250000u);
        if (first != 'P') continue;
        started = CYCLE;
        int second = get_byte(started, 12500000u);
        while (second == 'P') second = get_byte(started, 12500000u);
        if (second != 'G') continue;
        uint8_t header[4];
        uint16_t checksum = 0xFFFFu;
        uint32_t complete = 1;
        if (UART_ERRORS) UART_CONTROL = 2;
        for (uint32_t index = 0; index < 4; index++) {
            int value = get_byte(started, 12500000u);
            if (value < 0) { complete = 0; break; }
            header[index] = (uint8_t)value;
            checksum = crc_update(checksum, (uint8_t)value);
        }
        if (!complete) continue;
        uint16_t length = header[2] | ((uint16_t)header[3] << 8);
        if (length > sizeof(packet)) { status_response(header[0], header[1], 1); continue; }
        for (uint32_t index = 0; index < length; index++) {
            int value = get_byte(started, 12500000u);
            if (value < 0) { complete = 0; break; }
            packet[index] = (uint8_t)value;
            checksum = crc_update(checksum, (uint8_t)value);
        }
        if (!complete) continue;
        int low = get_byte(started, 12500000u);
        int high = get_byte(started, 12500000u);
        if (low < 0 || high < 0) continue;
        if (UART_ERRORS) { UART_CONTROL = 1; status_response(header[0], header[1], 9); continue; }
        if (checksum != (uint16_t)(low | (high << 8))) { status_response(header[0], header[1], 1); continue; }
        process(header[0], header[1], length);
    }
}
