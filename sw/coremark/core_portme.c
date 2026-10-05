/* ============================================================================
 * core_portme.c — CoreMark 本平台移植层 (RV32I / 达芬奇Pro)
 * ----------------------------------------------------------------------------
 * 计时: MMIO 的 64 位自由运行周期计数器 (rv32_pkg: MMIO_CYCLE_LO/HI)
 * 输出: 写入 dmem 日志缓冲区 (0x9000_3000), 由仿真 tb 或硬件 ILA 读取
 *
 * CoreMark/MHz 的算法 (时钟会自动约掉):
 *     CoreMark/MHz = iterations / (ticks / f) / (f / 1e6)
 *                  = iterations * 1e6 / ticks
 *   所以只要拿到 "Total ticks" 和 "Iterations" 两行就够, 与主频无关。
 * ========================================================================== */

#include "coremark.h"
#include "core_portme.h"

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

/* ---- 日志输出: 写进 dmem 日志缓冲区 (sw/link.ld 定义的 0x9000_3000) ---- */
#define LOG_BASE  ((volatile char *)0x90003000u)
#define LOG_LIMIT 0x1000u
static ee_u32 log_pos = 0;

void
uart_send_char(char c)
{
    if (log_pos < LOG_LIMIT - 1u)
        LOG_BASE[log_pos++] = c;
    LOG_BASE[log_pos] = 0;   /* 保持 NUL 结尾, tb 可直接当字符串读 */
}

/* ---- MMIO ---- */
#define MMIO_CYCLE_LO (*(volatile ee_u32 *)0xA0000008u)
#define MMIO_CYCLE_HI (*(volatile ee_u32 *)0xA000000Cu)
#define TOHOST_ADDR   (*(volatile ee_u32 *)0x90002000u)

static ee_u32
read_cycles_lo(void)
{
    return MMIO_CYCLE_LO;
}
static ee_u32
read_cycles_hi(void)
{
    return MMIO_CYCLE_HI;
}

/* 64 位读: 避免读低 32 位时高 32 位进位 */
static unsigned long long
read_cycles64(void)
{
    ee_u32 hi, lo, hi2;
    do
    {
        hi  = read_cycles_hi();
        lo  = read_cycles_lo();
        hi2 = read_cycles_hi();
    } while (hi != hi2);
    return (((unsigned long long)hi) << 32) | (unsigned long long)lo;
}

CORETIMETYPE
barebones_clock(void)
{
    return (CORETIMETYPE)read_cycles64();
}

#define GETMYTIME(_t)              (*_t = barebones_clock())
#define MYTIMEDIFF(fin, ini)       ((fin) - (ini))
#define TIMER_RES_DIVIDER          1
#define SAMPLE_TIME_IMPLEMENTATION 1
/* ticks 就是 CPU 周期, 所以每秒 ticks 数 = 主频 */
#define EE_TICKS_PER_SEC           (CLOCKS_PER_SEC / TIMER_RES_DIVIDER)

static CORETIMETYPE start_time_val, stop_time_val;

/* 上板跑分观测寄存器 (见 rv32_pkg 的 MMIO_* 常量).
 * 串口在本板不通, 只能靠 ILA over JTAG 把结果读回来:
 *   MMIO_MARK   写一次 -> 单拍脉冲, 做 ILA 的触发点 (= 测量区间起点)
 *   MMIO_RESULT 写 tick 数 -> 锁存并置 done                          */
#define MMIO_MARK_ADDR   0xA0000020u
#define MMIO_RESULT_ADDR 0xA0000024u

/* 由 core_main.c 在测完 CRC 后填入 (results[] 是 main() 的局部变量, 拿不到).
 * 上板只能回读一个 32 位寄存器, 所以把"算得对不对"和"跑了多少拍"打包:
 *   bit31    = 1 表示三个数据类 CRC 全部等于 CoreMark 官方参考值
 *   bit30:0  = 实测 tick 数 (1200 次迭代约 5.08e8, 只占 29 位)
 * 这三个 CRC 与迭代次数无关 (实测 ITERATIONS=1 与 3 完全一致), 所以是硬判据。 */
volatile unsigned int g_crclist   = 0;
volatile unsigned int g_crcmatrix = 0;
volatile unsigned int g_crcstate  = 0;

#define CRC_LIST_EXPECTED    0xe714u
#define CRC_MATRIX_EXPECTED  0x1fd7u
#define CRC_STATE_EXPECTED   0x8e3au

void
start_time(void)
{
    GETMYTIME(&start_time_val);
    *(volatile unsigned int *)MMIO_MARK_ADDR = 1u;   /* ILA 触发点 */
}

void
stop_time(void)
{
    GETMYTIME(&stop_time_val);
    /* 上报最终 tick 数给硬件 (ILA 抓取), 供 PC 端算 CoreMark/MHz。
     * 【为什么放这里而不是 exit()】实测 exit() 根本没被调用 —— 程序是靠 crt0
     * 在 main 返回后写 tohost 结束的, 所以放在 exit() 里的上报是被优化掉的死代码
     * (反汇编里只有 mark 那条 sw, 没有写 MMIO_RESULT 的)。stop_time() 在测量区间
     * 结束处必然执行, stop_time_val 此刻刚刚读到。 */
    {
        unsigned int crc_ok = (g_crclist   == CRC_LIST_EXPECTED)   &&
                              (g_crcmatrix == CRC_MATRIX_EXPECTED) &&
                              (g_crcstate  == CRC_STATE_EXPECTED);
        unsigned int ticks  = (unsigned int)MYTIMEDIFF(stop_time_val, start_time_val);
        *(volatile unsigned int *)MMIO_RESULT_ADDR =
            (crc_ok ? 0x80000000u : 0x00000000u) | (ticks & 0x7fffffffu);
    }
}

CORE_TICKS
get_time(void)
{
    return (CORE_TICKS)(MYTIMEDIFF(stop_time_val, start_time_val));
}

secs_ret
time_in_secs(CORE_TICKS ticks)
{
    return ((secs_ret)ticks) / (secs_ret)EE_TICKS_PER_SEC;
}

ee_u32 default_num_contexts = 1;

void
portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;

    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *))
        ee_printf("ERROR! ee_ptr_int must hold a pointer!\n");
    if (sizeof(ee_u32) != 4)
        ee_printf("ERROR! ee_u32 must be 32b!\n");
    if (sizeof(CORE_TICKS) < 8)
        ee_printf("ERROR! CORE_TICKS must be 64b!\n");

    p->portable_id = 1;
}

void
portable_fini(core_portable *p)
{
    p->portable_id = 0;
}

/* CoreMark 结束后由 core_main.c 调 exit(); 我们借它通知宿主。
 * 注意: 报告"跑完"和"PASS"是两件事 —— 结果是否有效由 crc 行判定。 */
void
exit(int code)
{
    (void)code;
    /* 结果已在 stop_time() 上报; 这里保留一次写只是为了兼容可能直接走到 exit() 的流程 */
    *(volatile unsigned int *)MMIO_RESULT_ADDR =
        (unsigned int)MYTIMEDIFF(stop_time_val, start_time_val);
    TOHOST_ADDR = 1u;
    for (;;)
    {
    }
}
