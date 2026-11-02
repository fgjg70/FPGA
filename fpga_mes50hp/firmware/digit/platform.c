#include "platform.h"

static uint32_t io_control;
static uint32_t peripheral_status;
static uint32_t active_slot;

uint16_t crc_update(uint16_t crc, uint8_t value) {
    crc ^= (uint16_t)value << 8;
    for (uint32_t bit_index = 0; bit_index < 8; bit_index++)
        crc = (crc & 0x8000u) ? (uint16_t)((crc << 1) ^ 0x1021u) : (uint16_t)(crc << 1);
    return crc;
}

static void delay_cycles(uint32_t count) {
    uint32_t started = CYCLE;
    do { app_service(); } while ((uint32_t)(CYCLE - started) < count);
}

static void bus_lines(uint32_t bus, uint32_t clock_high, uint32_t data_high) {
    uint32_t shift = bus * 2;
    io_control = (io_control & ~(3u << shift)) | ((clock_high | (data_high << 1)) << shift);
    I2C_OUTPUT = io_control;
}

static int clock_high(uint32_t bus, uint32_t data_high) {
    bus_lines(bus, 1, data_high);
    uint32_t started = CYCLE;
    while (!(I2C_INPUT & (1u << (bus * 2)))) {
        app_service();
        if ((uint32_t)(CYCLE - started) >= 50000u) return -1;
    }
    delay_cycles(200);
    return 0;
}

static int bus_start(uint32_t bus) {
    if (clock_high(bus, 1)) return -1;
    if (!(I2C_INPUT & (2u << (bus * 2)))) return -1;
    bus_lines(bus, 1, 0);
    delay_cycles(200);
    bus_lines(bus, 0, 0);
    return 0;
}

static void bus_stop(uint32_t bus) {
    bus_lines(bus, 0, 0);
    delay_cycles(200);
    clock_high(bus, 0);
    bus_lines(bus, 1, 1);
    delay_cycles(200);
}

static int bus_write(uint32_t bus, uint8_t value) {
    for (uint32_t bit_index = 0; bit_index < 8; bit_index++) {
        uint32_t data_high = (value >> (7 - bit_index)) & 1u;
        bus_lines(bus, 0, data_high);
        delay_cycles(200);
        if (clock_high(bus, data_high)) return -1;
        bus_lines(bus, 0, data_high);
    }
    bus_lines(bus, 0, 1);
    delay_cycles(200);
    if (clock_high(bus, 1)) return -1;
    int acknowledged = !(I2C_INPUT & (2u << (bus * 2)));
    bus_lines(bus, 0, 1);
    delay_cycles(200);
    return acknowledged ? 0 : -1;
}

static int bus_read(uint32_t bus, uint32_t last, uint8_t *result) {
    uint8_t value = 0;
    for (uint32_t bit_index = 0; bit_index < 8; bit_index++) {
        bus_lines(bus, 0, 1);
        delay_cycles(200);
        if (clock_high(bus, 1)) return -1;
        value = (uint8_t)((value << 1) | ((I2C_INPUT >> (bus * 2 + 1)) & 1u));
        bus_lines(bus, 0, 1);
    }
    bus_lines(bus, 0, last);
    delay_cycles(200);
    if (clock_high(bus, last)) return -1;
    bus_lines(bus, 0, 1);
    delay_cycles(200);
    *result = value;
    return 0;
}

static void recover_bus(uint32_t bus) {
    for (uint32_t pulse = 0; pulse < 9; pulse++) {
        bus_lines(bus, 0, 1);
        delay_cycles(200);
        if (clock_high(bus, 1)) break;
    }
    bus_stop(bus);
}

static int eeprom_read(uint8_t offset, uint8_t *data, uint32_t count) {
    int failed = bus_start(0) || bus_write(0, 0xA0) || bus_write(0, offset) ||
                 bus_start(0) || bus_write(0, 0xA1);
    for (uint32_t index = 0; index < count && !failed; index++)
        failed = bus_read(0, index + 1 == count, data + index);
    bus_stop(0);
    return failed ? -1 : 0;
}

static int eeprom_wait_ready(void) {
    uint32_t started = CYCLE;
    do {
        int ready = !bus_start(0) && !bus_write(0, 0xA0);
        bus_stop(0);
        if (ready) return 0;
        delay_cycles(5000);
    } while ((uint32_t)(CYCLE - started) < 500000u);
    return -1;
}

static int eeprom_write(uint8_t offset, const uint8_t *data, uint32_t count) {
    if (count == 0 || count > 8 || (offset & 7u) + count > 8) return -1;
    int failed = bus_start(0) || bus_write(0, 0xA0) || bus_write(0, offset);
    for (uint32_t index = 0; index < count && !failed; index++) failed = bus_write(0, data[index]);
    bus_stop(0);
    return failed ? -1 : eeprom_wait_ready();
}

static uint32_t get_word(const uint8_t *data) {
    return data[0] | ((uint32_t)data[1] << 8) | ((uint32_t)data[2] << 16) | ((uint32_t)data[3] << 24);
}

static void put_word(uint8_t *data, uint32_t value) {
    for (uint32_t index = 0; index < 4; index++) data[index] = (uint8_t)(value >> (index * 8));
}

static int valid_record(const uint8_t *record) {
    if (record[0] != 'P' || record[1] != 'C' || record[2] != 2 || record[3] > 2 || record[18] != 0xA5) return 0;
    for (uint32_t index = 4; index < 8; index++) if (record[index] > 9) return 0;
    uint32_t unlock_ms = get_word(record + 8);
    if (unlock_ms < 1000 || unlock_ms > 30000) return 0;
    uint16_t checksum = 0xFFFFu;
    for (uint32_t index = 0; index < 16; index++) checksum = crc_update(checksum, record[index]);
    return record[16] == (uint8_t)checksum && record[17] == (uint8_t)(checksum >> 8);
}

int platform_save(configuration_t *configuration) {
    uint8_t record[24], verified[24];
    for (uint32_t index = 0; index < 24; index++) record[index] = 0;
    record[0] = 'P'; record[1] = 'C'; record[2] = 2; record[3] = (uint8_t)configuration->mode;
    for (uint32_t index = 0; index < 4; index++) record[index + 4] = configuration->pin[index];
    put_word(record + 8, configuration->unlock_ms);
    put_word(record + 12, configuration->generation + 1);
    uint16_t checksum = 0xFFFFu;
    for (uint32_t index = 0; index < 16; index++) checksum = crc_update(checksum, record[index]);
    record[16] = (uint8_t)checksum; record[17] = (uint8_t)(checksum >> 8);
    uint32_t target = active_slot == 0 ? 32 : 0;
    uint8_t marker = 0;
    int failed = eeprom_write((uint8_t)(target + 18), &marker, 1);
    for (uint32_t index = 0; index < 24 && !failed; index += 8)
        failed = eeprom_write((uint8_t)(target + index), record + index, 8);
    marker = 0xA5;
    if (!failed) failed = eeprom_write((uint8_t)(target + 18), &marker, 1);
    if (!failed) failed = eeprom_read((uint8_t)target, verified, 24);
    if (!failed) {
        record[18] = 0xA5;
        for (uint32_t index = 0; index < 24; index++) failed |= record[index] != verified[index];
        failed |= !valid_record(verified);
    }
    if (failed) {
        peripheral_status |= 4u;
        return -1;
    }
    peripheral_status = (peripheral_status | 3u) & ~4u;
    active_slot = target;
    configuration->generation++;
    return 0;
}

static int hdmi_write(uint16_t address, uint8_t value) {
    int failed = bus_start(1) || bus_write(1, 0xB2) || bus_write(1, (uint8_t)address) ||
                 bus_write(1, (uint8_t)(address >> 8)) || bus_write(1, value);
    bus_stop(1);
    return failed ? -1 : 0;
}

static int hdmi_read(uint16_t address, uint8_t *value) {
    int failed = bus_start(1) || bus_write(1, 0xB2) || bus_write(1, (uint8_t)address) ||
                 bus_write(1, (uint8_t)(address >> 8)) || bus_start(1) || bus_write(1, 0xB3) || bus_read(1, 1, value);
    bus_stop(1);
    return failed ? -1 : 0;
}

static int hdmi_initialize(void) {
    static const struct { uint16_t address; uint8_t value; } setup[] = {
        {0x1281,0x04},{0x0060,0x81},{0x0060,0x54},{0x0016,0x04},{0x0009,0x01},
        {0x0079,0x20},{0x1200,0x04},{0x1201,0x00},{0x1202,0x00},{0x1262,0x00},
        {0x1263,0x00},{0x1265,0x00},{0x0007,0x09},{0x0008,0xF0},{0x000A,0xF0},
        {0x0006,0x11},{0x0900,0x20},{0x0901,0x47},{0x0904,0x09},{0x0923,0x07},
        {0x0924,0x44},{0x0925,0x44},{0x090F,0x80},{0x091F,0x00},{0x0920,0x1A},
        {0x0018,0x20},{0x05C0,0xFE},{0x000B,0x00},{0x0507,0x06},{0x0581,0x04},
        {0x0581,0x00},{0x0906,0x00},{0x0926,0x11},{0x0927,0x01},{0x0928,0x11},
        {0x0929,0x01},{0x092A,0x00},{0x0905,0x02},{0x0503,0x00},{0x0508,0x00},
        {0x1206,0x03},{0x120B,0x34}
    };
    static const uint16_t timing[] = {864,625,135,2,64,5,132,852,44,620,357,645};
    uint8_t value;
    if (hdmi_write(0x0003, 0x5A) || hdmi_read(0x0003, &value) || value != 0x5A) return -1;
    for (uint32_t index = 0; index < sizeof(setup) / sizeof(setup[0]); index++)
        if (hdmi_write(setup[index].address, setup[index].value)) return -1;
    for (uint32_t index = 0; index < sizeof(timing) / sizeof(timing[0]); index++)
        if (hdmi_write((uint16_t)(0x120C + index * 2), (uint8_t)timing[index]) ||
            hdmi_write((uint16_t)(0x120D + index * 2), (uint8_t)(timing[index] >> 8))) return -1;
    delay_cycles(500000);
    if (hdmi_write(0x0910, 1)) return -1;
    delay_cycles(500000);
    if (hdmi_write(0x000B, 0x11) || hdmi_write(0x050E, 0) || hdmi_write(0x050A, 0x82) ||
        hdmi_write(0x0509, 2) || hdmi_write(0x050B, 13)) return -1;
    static const uint8_t infoframe[] = {0xF4,0x12,0x58,0,17,0,0,0,0,0,0,0,0,0};
    for (uint32_t index = 0; index < sizeof(infoframe); index++)
        if (hdmi_write(0x050D, infoframe[index])) return -1;
    if (hdmi_write(0x050E, 0x40) || hdmi_write(0x0507, 4) || hdmi_write(0x091F, 7) || hdmi_write(0x0920, 0x1E)) return -1;
    return hdmi_read(0x1202, &value) || value != 0 ? -1 : 0;
}

void platform_initialize(configuration_t *configuration) {
    uint8_t records[2][24];
    uint32_t valid[2] = {0,0};
    io_control = 15;
    I2C_OUTPUT = io_control;
    peripheral_status = 0;
    active_slot = 0xFFFFFFFFu;
    recover_bus(0);
    uint32_t eeprom_ready = !eeprom_wait_ready();
    for (uint32_t slot = 0; slot < 2 && eeprom_ready; slot++) {
        if (!eeprom_read((uint8_t)(slot * 32), records[slot], 24)) {
            peripheral_status |= 1;
            valid[slot] = (uint32_t)valid_record(records[slot]);
        }
    }
    if (valid[0] || valid[1]) {
        uint32_t slot = valid[1] && (!valid[0] || (int32_t)(get_word(records[1] + 12) - get_word(records[0] + 12)) > 0);
        for (uint32_t index = 0; index < 4; index++) configuration->pin[index] = records[slot][index + 4];
        configuration->mode = records[slot][3];
        configuration->unlock_ms = get_word(records[slot] + 8);
        configuration->generation = get_word(records[slot] + 12);
        active_slot = slot * 32;
        peripheral_status |= 2;
    }
    delay_cycles(50000);
    io_control |= 16;
    I2C_OUTPUT = io_control;
    delay_cycles(500000);
    recover_bus(1);
    if (!hdmi_initialize()) peripheral_status |= 8;
}

uint32_t platform_status(void) {
    return peripheral_status;
}
