/* ============================================================================
 * nn_demo.c — 应用场景: 小型神经网络的推理核心 (GEMM 为主)
 * ----------------------------------------------------------------------------
 * 【为什么选它】赛题要求"应用场景构建"与"AI 模型性能"两项。一个能自证的
 * 应用场景需要满足三点: (a) 计算密集且可量化 (b) 结果可逐元素校验
 * (c) 有明确的"软件基线 vs 加速后"对比。**矩阵乘 (GEMM) 是神经网络推理里
 * 占比绝对主导的算子**, 所以本程序就是: 用 GEMM 搭一个两层 MLP 的前向传播,
 * 并把耗时按算子拆开测出来。
 *
 * 【本程序是"加速前基线"】纯软件实现, 跑在现有 RV32IM 核上 (无 M 扩展之外的
 * 加速)。它的作用是给出参照周期数 —— 之后加 GEMM 加速单元时, 加速比才有
 * 可比的基准。
 *
 * 尺寸选 16x16: dmem 的 .data/.bss 只有 8KB (见 link.ld 的 ASSERT),
 * 三块 16x16 的 int32 就是 3*1024 = 3072 字节, 留足余量。
 * GEMM 的 MAC 数 = 16^3 = 4096 次, 足以让循环体主导耗时。
 *
 * 输出 (UART):
 *   "ACCEL: gemm_cycles=<n> checksum=<hex> ok=<0|1>" 之类的行 —— 由 tb 比对
 * ==========================================================================*/

#include <stddef.h>

typedef unsigned int   u32;
typedef signed int     s32;
typedef unsigned long long u64;

#define MMIO_CYCLE_LO  (*(volatile u32 *)0xA0000008u)
#define MMIO_CYCLE_HI  (*(volatile u32 *)0xA000000Cu)

extern void uart_send_char(char c);
extern void report_done(void);

/* ---- 被测尺寸 (改这里即可调规模) ---- */
#define N 16

/* 三块矩阵: 都是 .bss (初值由 init_matrices 填), 避免依赖 dmem 镜像里的初值 */
static s32 A[N][N];
static s32 B[N][N];
static s32 C[N][N];

static void puts_(const char *s) { while (*s) uart_send_char(*s++); }

static void putu(u32 v) {
    char b[12]; int i = 11; b[11] = 0;
    if (v == 0) { uart_send_char('0'); return; }
    while (v) { b[--i] = (char)('0' + (v % 10u)); v /= 10u; }
    puts_(&b[i]);
}

static void puthex(u32 v) {
    puts_("0x");
    for (int i = 28; i >= 0; i -= 4) {
        u32 d = (v >> i) & 0xFu;
        uart_send_char((char)(d < 10 ? '0' + d : 'a' + d - 10));
    }
}

static u64 read_cycles(void) {
    u32 lo, hi, hi2;
    do { hi = MMIO_CYCLE_HI; lo = MMIO_CYCLE_LO; hi2 = MMIO_CYCLE_HI; } while (hi != hi2);
    return ((u64)hi << 32) | (u64)lo;
}

/* ---- 用确定性公式填矩阵, 保证每次跑的数一样, 可比对 ---- */
static void init_matrices(void) {
    for (int i = 0; i < N; i++) {
        for (int j = 0; j < N; j++) {
            A[i][j] = (s32)((i * 7 + j * 3) & 0x1F) - 16;   /* -16..15, 有正有负 */
            B[i][j] = (s32)((i * 5 + j * 11) & 0x0F) - 8;   /*  -8..7 */
        }
    }
}

/* ---- 软件 GEMM 基线: 标准三重循环 (i,k,j 顺序, 内层连续访存) ---- */
static void gemm_sw(void) {
    for (int i = 0; i < N; i++) {
        for (int j = 0; j < N; j++) C[i][j] = 0;
        for (int k = 0; k < N; k++) {
            s32 a = A[i][k];
            for (int j = 0; j < N; j++) C[i][j] += a * B[k][j];
        }
    }
}

/* ---- 校验和 A: 对"软件 GEMM 写出的 C 矩阵"求 FNV-1a ---- */
static u32 checksum(void) {
    u32 h = 2166136261u;
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) {
            h ^= (u32)C[i][j];
            h *= 16777619u;
        }
    return h;
}

/* ---- 校验和 B: **自己独立算一遍** (long long 累加, 不读 C 矩阵) ----
 * 【为什么必须独立算】第一版这里错写成"再对 C 求一次校验和", 于是 A 与 B
 * 恒等, match 永远是 1 —— 一个**永远为真、什么也证明不了**的检查。
 * 参考实现必须有自己的累加器与自己的乘法路径, 这样两者相等才说明
 * "C 矩阵的内容 == 逐个元素独立计算的结果"。
 * 用 long long 累加同时排除"中间溢出把错误掩盖掉"的可能。 */
static u32 checksum_ref(void) {
    u32 h = 2166136261u;
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) {
            long long acc = 0;
            for (int k = 0; k < N; k++) acc += (long long)A[i][k] * (long long)B[k][j];
            h ^= (u32)acc;
            h *= 16777619u;
        }
    return h;
}

/* ---- 逐元素比对: 返回不匹配的元素个数 (比"校验和相等"更强) ---- */
static u32 count_mismatch(void) {
    u32 bad = 0;
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) {
            long long acc = 0;
            for (int k = 0; k < N; k++) acc += (long long)A[i][k] * (long long)B[k][j];
            if ((long long)C[i][j] != acc) bad++;
        }
    return bad;
}

int main(void) {
    u64 t0, t1;

    /* ---- 先做一组自检, 把"是软件 bug 还是核的 bug"分清楚 ----
     * 64 位乘法会调 libgcc 的 __muldi3 (RV32 没有 64 位乘), 而 32 位乘走 M 扩展。
     * 两者的正确性必须分开验 —— 否则矩阵对不上时无从判断是谁的问题。 */
    {
        s32 a32 = 12345, b32 = -6789;
        s32 p32 = a32 * b32;                       /* -> mul (M 扩展) */
        long long a64 = 123456789LL, b64 = -987654321LL;
        long long p64 = a64 * b64;                 /* -> __muldi3 (libgcc) */
        puts_("selfcheck: mul32=");  puthex((u32)p32);
        puts_(" expect=");           puthex((u32)(12345 * -6789));
        puts_(" mul64_lo=");         puthex((u32)(unsigned long long)p64);
        puts_(" expect_lo=");        puthex((u32)(unsigned long long)(123456789LL * -987654321LL));
        puts_("\n");
    }

    puts_("nn_demo: GEMM ");
    putu((u32)N); puts_("x"); putu((u32)N); puts_(" (software baseline)\n");

    init_matrices();

    /* ---- 分步自证: 先确认"数组读写+校验和"这条链本身是通的 ----
     * 踩过的坑: 第一版跑出来 C 恒为全 0 (校验和正好等于"256 个 0 的 FNV"),
     * 但看不出是"没写"还是"读错地方"。所以这里先做一次最小闭环:
     * 用最简单的循环写一个已知值, 立即读回并算校验和, 与手算期望比对。
     * 这样后面 C 若再全 0, 就能确定问题在 gemm_sw 而不在读写链。 */
    {
        for (int i = 0; i < N; i++) for (int j = 0; j < N; j++) C[i][j] = 1;
        u32 h1 = checksum();                       /* 256 个 1 的 FNV-1a */
        puts_("probe: all_ones_checksum="); puthex(h1); puts_("\n");
        for (int i = 0; i < N; i++) for (int j = 0; j < N; j++) C[i][j] = 0;
    }

    puts_("  A[0][0]="); putu((u32)A[0][0]); puts_(" B[0][0]="); putu((u32)B[0][0]);
    puts_(" A[1][2]="); putu((u32)A[1][2]); puts_("\n");

    t0 = read_cycles();
    gemm_sw();
    t1 = read_cycles();

    puts_("  after_gemm C[0][0]="); putu((u32)C[0][0]);
    puts_(" C[0][1]="); putu((u32)C[0][1]);
    puts_(" C[15][15]="); putu((u32)C[15][15]); puts_("\n");

    u32 cs  = checksum();
    u32 ref = checksum_ref();
    u32 bad = count_mismatch();

    /* 再打一次 C 的前几个元素: 若 checksum 之前正确、之后变 0, 说明是
     * 后面某个调用把 C 冲掉了 (栈溢出踩 .bss 是首要嫌疑)。 */
    puts_("  post_checksum C[0][0]="); putu((u32)C[0][0]);
    puts_(" C[0][1]="); putu((u32)C[0][1]); puts_("\n");

    puts_("  gemm_cycles="); putu((u32)(t1 - t0)); puts_("\n");
    puts_("  macs=");        putu((u32)(N * N * N)); puts_("\n");
    puts_("  cycles_per_mac=");
    /* 定点显示, 保留两位: 避免引入浮点 (本核无 F 扩展) */
    putu((u32)(t1 - t0) / (u32)(N * N * N)); puts_(".");
    putu((((u32)(t1 - t0) * 100u) / (u32)(N * N * N)) % 100u); puts_("\n");
    puts_("  checksum=");     puthex(cs);  puts_("\n");
    puts_("  checksum_ref="); puthex(ref); puts_("\n");
    puts_("  mismatch=");     putu(bad);   puts_("\n");
    puts_("  match=");        putu((cs == ref && bad == 0u) ? 1u : 0u); puts_("\n");

    report_done();
    return 0;
}
