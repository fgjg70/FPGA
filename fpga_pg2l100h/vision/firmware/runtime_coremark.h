#ifndef RUNTIME_COREMARK_H
#define RUNTIME_COREMARK_H

#include <stdint.h>

int coremark_main(void);
void coremark_runtime_begin(void);

static uint32_t coremark_bcd(uint32_t value) {
    uint32_t packed = 0;
    for (unsigned digit = 0; digit < 8; digit++) {
        packed |= (value % 10u) << (digit * 4);
        value /= 10u;
    }
    return packed;
}

static void coremark_publish(unsigned state) {
    REG(0x34) = (2u << 23) | state;
    REG(0x38) = coremark_bcd(REG(0x70));
    REG(0x3c) = coremark_bcd(REG(0x74));
    REG(0x2c) = 1;
}

static void run_coremark(void) {
    REG(0x18) = 0;
    REG(0x5c) = 2;
    REG(0x28) = 0;
    for (unsigned index = 0; index < 3; index++) REG(0xa8 + index * 16) = 0;
    coremark_runtime_begin();
    coremark_publish(1);
    coremark_main();
    coremark_publish(REG(0x6c));
}

#endif
