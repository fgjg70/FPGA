#ifndef CORE_PORTME_H
#define CORE_PORTME_H
#include <stddef.h>
#include <stdint.h>

#define HAS_FLOAT 0
#define HAS_TIME_H 0
#define USE_CLOCK 0
#define HAS_STDIO 0
#define HAS_PRINTF 0
#define COMPILER_VERSION __VERSION__
#include "benchmark_flags.h"
#define MEM_LOCATION "FPGA on-chip DMEM"
#define SEED_METHOD SEED_VOLATILE
#define MEM_METHOD MEM_STATIC
#define MULTITHREAD 1
#define MAIN_HAS_NOARGC 1
#define MAIN_HAS_NORETURN 0
#include "platform_clock.h"
#define CLOCKS_PER_SEC CLOCK_HZ
#define CORETIMETYPE uint64_t

typedef int16_t ee_s16;
typedef uint16_t ee_u16;
typedef int32_t ee_s32;
typedef uint32_t ee_u32;
typedef uint8_t ee_u8;
typedef double ee_f32;
typedef uintptr_t ee_ptr_int;
typedef size_t ee_size_t;
typedef uint64_t CORE_TICKS;
typedef struct { ee_u8 portable_id; } core_portable;
#define align_mem(pointer) (void *)((4 + (uintptr_t)(pointer) - 1) & ~(uintptr_t)3)

extern ee_u32 default_num_contexts;
void portable_init(core_portable *portable, int *argc, char *argv[]);
void portable_fini(core_portable *portable);
int ee_printf(const char *format, ...);
#endif
