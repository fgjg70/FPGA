#include <stdarg.h>
#include "coremark.h"

#define REG(offset) (*(volatile ee_u32 *)(0xa1000000u + (offset)))

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
#else
volatile ee_s32 seed1_volatile = 0;
volatile ee_s32 seed2_volatile = 0;
#endif
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;
ee_u32 default_num_contexts = 1;
static CORE_TICKS start_ticks;
static CORE_TICKS stop_ticks;

static CORE_TICKS read_ticks(void) {
    ee_u32 upper;
    ee_u32 lower;
    ee_u32 repeated;
    do { upper = REG(0x48); lower = REG(0x1c); repeated = REG(0x48); } while (upper != repeated);
    return ((CORE_TICKS)upper << 32) | lower;
}

static void serial_char(char character) {
    while (REG(0x84) & 1u) { }
    if (character == '\n') {
        REG(0x80) = '\r';
        while (REG(0x84) & 1u) { }
    }
    REG(0x80) = (ee_u8)character;
}

static void serial_number(ee_u32 value, unsigned base, unsigned width, char padding) {
    char digits[32];
    unsigned count = 0;
    do { unsigned remainder = value % base; digits[count++] = "0123456789abcdef"[remainder]; value /= base; } while (value);
    while (width > count) { serial_char(padding); width--; }
    while (count) serial_char(digits[--count]);
}

int ee_printf(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    while (*format) {
        if (*format != '%') { serial_char(*format++); continue; }
        format++;
        char padding = *format == '0' ? '0' : ' ';
        unsigned width = 0;
        while (*format >= '0' && *format <= '9') width = width * 10 + (unsigned)(*format++ - '0');
        int long_value = *format == 'l';
        if (long_value) format++;
        char specifier = *format++;
        if (specifier == 's') {
            const char *text = va_arg(arguments, const char *);
            while (*text) serial_char(*text++);
        } else if (specifier == 'c') serial_char((char)va_arg(arguments, int));
        else if (specifier == '%') serial_char('%');
        else if (specifier == 'd' || specifier == 'i') {
            ee_s32 value = long_value ? (ee_s32)va_arg(arguments, long) : va_arg(arguments, int);
            ee_u32 magnitude = (ee_u32)value;
            if (value < 0) { serial_char('-'); magnitude = 0u - magnitude; }
            serial_number(magnitude, 10, width, padding);
        } else {
            ee_u32 value = long_value ? (ee_u32)va_arg(arguments, unsigned long) : va_arg(arguments, unsigned);
            serial_number(value, specifier == 'x' ? 16 : 10, width, padding);
        }
    }
    va_end(arguments);
    return 0;
}

void start_time(void) { start_ticks = read_ticks(); }
void stop_time(void) {
    stop_ticks = read_ticks();
    CORE_TICKS elapsed = stop_ticks - start_ticks;
    ee_printf("CM64 ticks=%08x%08x clock=%u iterations=%u\n", (ee_u32)(elapsed >> 32), (ee_u32)elapsed, CLOCKS_PER_SEC, (ee_u32)ITERATIONS);
}
CORE_TICKS get_time(void) { return stop_ticks - start_ticks; }
secs_ret time_in_secs(CORE_TICKS ticks) {
    ee_u32 seconds = 0;
    for (unsigned bit = 32; bit > 0; bit--) {
        CORE_TICKS multiple = (CORE_TICKS)CLOCKS_PER_SEC << (bit - 1);
        if (ticks >= multiple) { ticks -= multiple; seconds |= 1u << (bit - 1); }
    }
    return seconds;
}

void portable_init(core_portable *portable, int *argc, char *argv[]) {
    (void)argc;
    (void)argv;
    REG(0x18) = 0;
    portable->portable_id = 1;
    ee_printf("COREMARK27 CPU ONLY; OFFICIAL SOURCE; >=10 SECONDS REQUIRED\n");
}
void portable_fini(core_portable *portable) { portable->portable_id = 0; REG(0x50) = 0xc0decafeu; }
