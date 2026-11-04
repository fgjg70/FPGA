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

#if defined(COREMARK_RUNTIME) || defined(COREMARK_PERF)
static unsigned runtime_crc;
static unsigned runtime_errors;
static unsigned runtime_validated;

#ifdef COREMARK_RUNTIME
static uint64_t divide_ticks(uint64_t numerator, uint64_t denominator) {
    uint64_t quotient = 0;
    uint64_t remainder = 0;
    if (!denominator) return 0;
    for (unsigned bit = 64; bit; bit--) {
        unsigned carry = (unsigned)(remainder >> 63);
        remainder = (remainder << 1) | ((numerator >> (bit - 1)) & 1u);
        if (carry || remainder >= denominator) {
            remainder -= denominator;
            quotient |= (uint64_t)1 << (bit - 1);
        }
    }
    return quotient;
}
#endif

static unsigned contains(const char *text, const char *needle) {
    for (; *text; text++) {
        const char *source = text;
        const char *pattern = needle;
        while (*source && *source == *pattern) { source++; pattern++; }
        if (!*pattern) return 1;
    }
    return 0;
}

#ifdef COREMARK_RUNTIME
void coremark_runtime_begin(void) {
    runtime_crc = 0;
    runtime_errors = 0;
    runtime_validated = 0;
    start_ticks = 0;
    stop_ticks = 0;
    REG(0x6c) = 1;
    REG(0x70) = 0;
    REG(0x74) = 0;
    REG(0x50) = 0;
}
#endif

static void record_result(const char *format, va_list arguments) {
    va_list values;
    va_copy(values, arguments);
    if (contains(format, "seedcrc")) {
        if (va_arg(values, unsigned) == 0xe9f5u) runtime_crc |= 1u;
    } else if (contains(format, "crclist")) {
        (void)va_arg(values, int);
        if (va_arg(values, unsigned) == 0xe714u) runtime_crc |= 2u;
    } else if (contains(format, "crcmatrix")) {
        (void)va_arg(values, int);
        if (va_arg(values, unsigned) == 0x1fd7u) runtime_crc |= 4u;
    } else if (contains(format, "crcstate")) {
        (void)va_arg(values, int);
        if (va_arg(values, unsigned) == 0x8e3au) runtime_crc |= 8u;
    }
    if (contains(format, "ERROR!") || contains(format, "Errors detected") || contains(format, "Cannot validate")) runtime_errors++;
    if (contains(format, "Correct operation validated.")) runtime_validated = 1;
    va_end(values);
}
#endif

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
#if defined(COREMARK_RUNTIME) || defined(COREMARK_PERF)
    record_result(format, arguments);
#endif
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

#ifdef COREMARK_PERF
#define PERF_REG(offset) (*(volatile ee_u32 *)(0xa1001000u + (offset)))

static void print_performance(void) {
    static const char *names[] = {
        "cycles", "retired", "issue_cycles", "dual_issue_cycles", "dual_retire_cycles", "stall_cycles",
        "load_use_cycles", "muldiv_cycles", "lsu_cycles", "external_wait_cycles", "redirect_events",
        "flush_cycles", "issued", "cancelled_slots", "external_read_wait_cycles", "external_write_wait_cycles"
    };
    ee_printf("CM_PERF version=%u status=%u", PERF_REG(0x008), PERF_REG(0x004));
    for (unsigned index = 0; index < 16; index++) {
        ee_u32 lower = PERF_REG(0x100 + index * 8);
        ee_u32 upper = PERF_REG(0x104 + index * 8);
        ee_printf(" %s=%08x%08x", names[index], upper, lower);
    }
    ee_printf("\n");
}
#endif

void start_time(void) {
    start_ticks = read_ticks();
#ifdef COREMARK_PERF
    PERF_REG(0x004) = 1;
#endif
}
void stop_time(void) {
#ifdef COREMARK_PERF
    PERF_REG(0x004) = 2;
#endif
    stop_ticks = read_ticks();
    CORE_TICKS elapsed = stop_ticks - start_ticks;
    ee_printf("CM64 ticks=%08x%08x clock=%u iterations=%u cpu=%u\n", (ee_u32)(elapsed >> 32), (ee_u32)elapsed, CLOCKS_PER_SEC, (ee_u32)ITERATIONS, CPU_CLOCK_HZ);
#ifdef COREMARK_PERF
    print_performance();
#endif
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
void portable_fini(core_portable *portable) {
    portable->portable_id = 0;
#ifdef COREMARK_PERF
    PERF_REG(0x010) = 0x80u | runtime_crc | (runtime_errors ? 0x10u : 0u) |
                     (runtime_validated ? 0x20u : 0u) |
                     (stop_ticks - start_ticks >= (uint64_t)CLOCKS_PER_SEC * 10u ? 0x40u : 0u);
#endif
#ifdef COREMARK_RUNTIME
    CORE_TICKS elapsed = stop_ticks - start_ticks;
    ee_u32 per_mhz = (ee_u32)divide_ticks((uint64_t)ITERATIONS * CLOCKS_PER_SEC * 10000u, elapsed * (CPU_CLOCK_HZ / 1000000u));
    ee_u32 total = (ee_u32)divide_ticks((uint64_t)ITERATIONS * CLOCKS_PER_SEC * 100u, elapsed);
    unsigned passed = runtime_crc == 15u && runtime_validated && !runtime_errors && elapsed >= (uint64_t)CLOCKS_PER_SEC * 10u;
    REG(0x70) = per_mhz;
    REG(0x74) = total;
    REG(0x78) = runtime_crc;
    REG(0x6c) = passed ? 2u : (runtime_crc == 15u && elapsed < (uint64_t)CLOCKS_PER_SEC * 10u ? 4u : 3u);
    ee_printf("COREMARK RESULT cm_mhz_x10000=%u score_x100=%u crc_mask=%u valid=%u\n", per_mhz, total, runtime_crc, passed);
#endif
    REG(0x50) = 0xc0decafeu;
}
