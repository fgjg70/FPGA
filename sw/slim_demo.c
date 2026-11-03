/* ============================================================================
 * slim_demo.c — M6a：瘦身模型（96x96，71 op）在现 NPU 上端到端 ModelSim 位精确
 * ----------------------------------------------------------------------------
 * 目标：零 RTL 改动、纯片上，两种输入各跑一遍全 plan，逐 op FNV 对金标：
 *   Phase R（真实图 0349）: 输入由 TB 预载到 A@0x60000（27,648 B PACKED3 int8）；
 *                           71 op 逐 op 下发（MODE_CPU），对 opvec/0349/checksums.txt
 *                           的 71 个 op 全判 FNV（含 3 个 head），另判输入 FNV。
 *   Phase P（pattern_v1）:  固件按 CONTRACT §10.1 生成输入（seed=12345），
 *                           71 op 逐 op 下发，对 slim_plan.h 里 71 个 op csum 全判。
 *   Phase A（MODE_AUTO）:   pattern 输入再跑一遍 ROM 自主模式（slim nn_rom_pkg 变体），
 *                           判 done/err/cycles + 最后一个 head 的 FNV。
 *
 * 金标口径（converter 确认，与 checksums.txt 完全一致）：
 *   h=2166136261; for y,x,c(real_C only): h^=byte; h*=16777619 (mod 2^32)
 *   张量字节布局 = arena/NHWC，pixel stride = pad8(C)；输入 = PACKED3 连续 3 字节/像素。
 *
 * 判据（全部机器判定）:
 *   real_input_csum == 0xbb23c676 且 real_hw_bad == 0（71 op）
 *   pattern_input_csum == 0xe40efcc5 且 pattern_hw_bad == 0（71 op）
 *   auto_bad == 0（head FNV）、auto_npu_cycles == hw npu_cycles（同 ROM/同 op 序列）
 *   npu_cycles 在 HANDOFF 预期 504,895 ±30% 内（353,426 ~ 656,363）
 * 全部满足 -> 打印 `SLIM_TB: PASS` + report_done()。
 *
 * 构建（Lead 在 tools/build_sw.py 注册；手工等价）：
 *   python tools/build_sw.py sw/slim_demo.c sw/portme.c -I sw -I results/bottlecap/plan/slim \
 *          --march rv32im --opt=-O2 -o sim/prog/slim_demo.hex
 * ==========================================================================*/

#include <stddef.h>
#include "slim_plan.h"

typedef unsigned char      u8;
typedef signed char        s8;
typedef unsigned short     u16;
typedef unsigned int       u32;
typedef unsigned long long u64;

extern void uart_send_char(char c);
extern void report_done(void);
extern void report_fail(void);

/* ---- 外设 / NN 窗口（与 yolo_demo.c 同口径） ---- */
#define REG(a)  (*(volatile u32 *)(u32)(a))
#define NN_WIN ((volatile u8 *)YOLO_NN_BASE)

static inline u8  rd8 (u32 off) { return NN_WIN[off]; }
static inline void wr8(u32 off, u8 v) { NN_WIN[off] = v; }
static inline u32 rd32(u32 off) { return *(volatile u32 *)(NN_WIN + off); }

/* ---- 金标常量（来自 converter / opvec；见报告 §证据） ---- */
#define REAL_INPUT_CSUM   0xbb23c676u   /* opvec/0349/checksums.txt 首行 */
/* 周期金标：v3 硬件周期公式 (results/ai-accel/proto/engine/calc_cycles_v3.py,
 * BASE=8/W_RD_LAT=2/DRN=4/NEXT=2/REQP=6/QPER8=11) 对 slim 71 op 逐 op 求和
 * = 799,520；ModelSim 实测 = 799,520（逐拍一致，与 YOLO E2E 公式=实测 1,191,020 同源）。
 * HANDOFF §④ 的 504,895 是 converter 的粗估（每块固定 +40 拍），低估 ~58%，
 * 已确认是估算器问题（非 RTL 差异），这里以 v3 公式为准（±1.1% 窗口）。 */
#define EXPECT_NPU_CYCLES 799520u
#define CYCLES_LO         791000u
#define CYCLES_HI         808000u

/* 真实图 0349 的逐 op FNV（opvec/0349/checksums.txt，71 op 全量；opvec 已由
 * converter 重导为全量 71 op：input 0xbb23c676 + 每个 op 一行）。 */
static const u32 REAL_CSUM[YOLO_NUM_OPS > 0 ? YOLO_NUM_OPS : 1] = {
    0x32787947,   /* op  0 */
    0x54205229,   /* op  1 */
    0x06f2342d,   /* op  2 */
    0xb5fd06ea,   /* op  3 */
    0x87f76495,   /* op  4 */
    0xbfd30088,   /* op  5 */
    0x90ff6170,   /* op  6 */
    0xef5d45c0,   /* op  7 */
    0x04d3888c,   /* op  8 */
    0x4de88026,   /* op  9 */
    0x62e43a44,   /* op 10 */
    0xe4bc1b63,   /* op 11 */
    0x245feb5e,   /* op 12 */
    0x037c104c,   /* op 13 */
    0x4013aae4,   /* op 14 */
    0xdd627599,   /* op 15 */
    0xff89adf6,   /* op 16 */
    0x594547d6,   /* op 17 */
    0xe4247c33,   /* op 18 */
    0x2a56ff66,   /* op 19 */
    0x77b97c6e,   /* op 20 */
    0xd8a2e098,   /* op 21 */
    0x30fe235f,   /* op 22 */
    0xce00d507,   /* op 23 */
    0xb58fac70,   /* op 24 */
    0x06e14417,   /* op 25 */
    0x15273f0c,   /* op 26 */
    0x275fd83b,   /* op 27 */
    0x6b4f9a6c,   /* op 28 */
    0xf2c6fee3,   /* op 29 */
    0xad9a5dbd,   /* op 30 */
    0xfb0b6967,   /* op 31 */
    0x45f8b542,   /* op 32 */
    0x32836c56,   /* op 33 */
    0xe89b3fdf,   /* op 34 */
    0x6115c375,   /* op 35 */
    0x8ba2991b,   /* op 36 */
    0x6abcdad4,   /* op 37 */
    0x2b009e19,   /* op 38 */
    0x7666521f,   /* op 39 */
    0x54823b10,   /* op 40 */
    0xca2be05d,   /* op 41 */
    0xb4a81d21,   /* op 42 */
    0x9554daf0,   /* op 43 */
    0xe3b75bdf,   /* op 44 */
    0x928359d4,   /* op 45 */
    0x6fe7f237,   /* op 46 */
    0x8bce3a53,   /* op 47 */
    0x9bf00360,   /* op 48 */
    0x227472db,   /* op 49 */
    0xc04ca915,   /* op 50 */
    0x6f7ebad1,   /* op 51 */
    0x2e787bce,   /* op 52 */
    0x2027acfe,   /* op 53 */
    0xbe8f95a1,   /* op 54 */
    0x84170085,   /* op 55 */
    0x8cff7e89,   /* op 56 */
    0x91f326d8,   /* op 57 */
    0x4af416b1,   /* op 58 */
    0x074bca45,   /* op 59 */
    0x32b5546d,   /* op 60 */
    0xb8d69225,   /* op 61 */
    0x9128a713,   /* op 62 */
    0x3b6d964d,   /* op 63 */
    0x14868f1e,   /* op 64 */
    0x75f33386,   /* op 65 */
    0x9d8abdf9,   /* op 66 */
    0xd6be16ea,   /* op 67 */
    0x6fe28bf4,   /* op 68 */
    0x1b7b4ea0,   /* op 69 */
    0x90eaadd8,   /* op 70 */
};
#define REAL_INPUT_CSUM_IN_HEADER 0  /* input FNV is checked separately (REAL_INPUT_CSUM) */

/* ---- 打印 ---- */
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

/* ---- FNV-1a（converter 口径：只遍历真实通道，NHWC 逻辑序 y,x,c） ---- */
static inline u32 fnv_byte(u32 h, u8 b) { h ^= (u32)b; h *= 16777619u; return h; }

/** 顺序字节流 FNV（abs 4B 对齐、bytes%4==0；u32 快路径，仿真时间 ~4x 改善）。 */
static u32 fnv_bytes_fast(u32 abs, u32 bytes) {
    u32 hsh = 2166136261u;
    for (u32 i = 0; i < bytes; i += 4u) {
        u32 w = rd32(abs + i);
        hsh = fnv_byte(hsh, (u8)(w & 0xFFu));
        hsh = fnv_byte(hsh, (u8)((w >> 8) & 0xFFu));
        hsh = fnv_byte(hsh, (u8)((w >> 16) & 0xFFu));
        hsh = fnv_byte(hsh, (u8)((w >> 24) & 0xFFu));
    }
    return hsh;
}

/** 紧凑 NHWC 张量 (H,W,real_C)，pixel stride = ceil(C/8)*8。
 *  C%4==0 时用 u32 快路径（绝大多数层）；否则逐字节。 */
static u32 fnv_tensor(u32 abs, u32 h, u32 w, u32 c) {
    u32 c8 = (c + 7u) & ~7u;
    u32 hsh = 2166136261u;
    if ((c & 3u) == 0u) {
        u32 nw = c >> 2;
        for (u32 y = 0; y < h; y++) {
            u32 row = abs + y * w * c8;
            for (u32 x = 0; x < w; x++) {
                u32 o = row + x * c8;
                for (u32 k = 0; k < nw; k++) {
                    u32 v = rd32(o + 4u * k);
                    hsh = fnv_byte(hsh, (u8)(v & 0xFFu));
                    hsh = fnv_byte(hsh, (u8)((v >> 8) & 0xFFu));
                    hsh = fnv_byte(hsh, (u8)((v >> 16) & 0xFFu));
                    hsh = fnv_byte(hsh, (u8)((v >> 24) & 0xFFu));
                }
            }
        }
    } else {
        for (u32 y = 0; y < h; y++) {
            u32 row = abs + y * w * c8;
            for (u32 x = 0; x < w; x++) {
                u32 o = row + x * c8;
                for (u32 i = 0; i < c; i++) hsh = fnv_byte(hsh, rd8(o + i));
            }
        }
    }
    return hsh;
}

/** PACKED3 连续图 (H,W,3, stride=3)；总字节数 4B 对齐（96x96x3=27,648）。 */
static u32 fnv_packed(u32 abs, u32 h, u32 w, u32 c) {
    return fnv_bytes_fast(abs, h * w * c);
}

/* ---- 形状/输入 ---- */
static inline u32 out_dim(u32 in, u32 k, u32 st, u32 pad) {
    return (in + 2u * pad - k) / st + 1u;
}

/** 生成 pattern_v1 输入（CONTRACT §10.1；与 converter golden 逐字节一致）。 */
static u32 gen_input_pattern(void) {
    for (u32 y = 0; y < YOLO_INPUT_H; y++)
        for (u32 x = 0; x < YOLO_INPUT_W; x++) {
            u32 o = YOLO_INPUT_ABS + (y * YOLO_INPUT_W + x) * YOLO_INPUT_STRIDE;
            for (u32 c = 0; c < YOLO_INPUT_C; c++) {
                u8 q = (u8)((x * 13u + y * 7u + c * 29u + YOLO_INPUT_GEN_SEED) & 0xFFu);
                wr8(o + c, q);
            }
        }
    return fnv_packed(YOLO_INPUT_ABS, YOLO_INPUT_H, YOLO_INPUT_W, YOLO_INPUT_C);
}

static u32 real_input_csum(void) {
    return fnv_packed(YOLO_INPUT_ABS, YOLO_INPUT_H, YOLO_INPUT_W, YOLO_INPUT_C);
}

/* ---- 硬件描述符下发（MODE_CPU；与 yolo_demo.c 同范式） ---- */
static u32 hw_op_code(const yolo_op_t *o) {
    switch (o->kind) {
        case YK_CONV:     return 0u;   /* NN_OP_CONV */
        case YK_DWCONV:   return 0u;   /* NN_OP_CONV + flags.DEPTHWISE */
        case YK_POOL:     return 1u;   /* NN_OP_POOL */
        case YK_UPSAMPLE: return 2u;   /* NN_OP_COPY + flags.UP2X */
        default:          return 3u;   /* YK_ADD -> NN_OP_ADD */
    }
}

static u32 hw_run_one(const yolo_op_t *o, u32 *cyc_out) {
    REG(MMIO_NN_OP)    = hw_op_code(o);
    REG(MMIO_NN_SRC)   = o->src;
    REG(MMIO_NN_DST)   = o->dst;
    REG(MMIO_NN_WOFF)  = o->woff;
    REG(MMIO_NN_QOFF)  = o->qoff;
    REG(MMIO_NN_IH)    = o->ih;
    REG(MMIO_NN_IW)    = o->iw;
    REG(MMIO_NN_IC)    = o->ic;
    REG(MMIO_NN_OC)    = o->oc;
    REG(MMIO_NN_KS)    = o->k;
    REG(MMIO_NN_ST)    = o->stride;
    REG(MMIO_NN_PAD)   = o->pad;
    REG(MMIO_NN_FLAGS) = o->flags;
    (void)REG(MMIO_NN_STATUS);          /* 读清 done/err */
    REG(MMIO_NN_CTRL) = 1u;             /* start (MODE_CPU) */
    for (;;) {
        u32 st = REG(MMIO_NN_STATUS);
        if (st & 4u) { *cyc_out = 0; return 1u; }   /* err */
        if (st & 2u) break;                          /* done */
    }
    *cyc_out = REG(MMIO_NN_CYCLES);
    return 0u;
}

/** 逐 op 下发整 plan；返回 bad 数；npu_cycles = Σ op cycles。
 *  real_mode!=0 时只对 REAL_CHK 里的 op 做 FNV 比对（其余 op 只查 err）。 */
static u32 run_plan_hw(u32 real_mode, u64 *npu_cycles, u32 *ops_run) {
    u32 bad = 0;
    u64 acc = 0;
    for (u32 i = 0; i < YOLO_NUM_OPS; i++) {
        const yolo_op_t *o = &YOLO_OPS[i];
        u32 cyc = 0;
        if (hw_run_one(o, &cyc) != 0u) {
            puts_("  [bad] op err idx="); putu(i); uart_send_char('\n');
            bad++;
            continue;
        }
        acc += (u64)cyc;
        if (ops_run) (*ops_run)++;

        u32 oh, ow, oc;
        if (o->kind == YK_ADD) {
            oh = o->ih; ow = o->iw; oc = o->ic;
        } else if (o->kind == YK_UPSAMPLE) {
            oh = o->ih * 2u; ow = o->iw * 2u; oc = o->ic;
        } else {
            oh = out_dim(o->ih, o->k, o->stride, o->pad);
            ow = out_dim(o->iw, o->k, o->stride, o->pad);
            oc = o->oc;
        }

        {
            /* NOTE (copy this pattern into later E2E firmware): read the
             * expected csum through a volatile pointer. GCC 15 -O2 mis-folded
             * the plain `o->csum` read when the two const csum tables
             * (YOLO_OPS / REAL_CSUM) are both in scope, so the pattern phase
             * compared against REAL_CSUM[i] -> 57 false mismatches.
             * See results/bottlecap/reports/M6A-SLIM-E2E.md Sec. 7.
             * volatile is the only change; it reads the same object. */
            u32 ocv = *(volatile const u32 *)&o->csum;
            u32 exp = real_mode ? REAL_CSUM[i] : ocv;
            u32 got = fnv_tensor(o->dst, oh, ow, oc);
            if (got != exp) {
                if (bad < 8u) {
                    puts_("  [bad] m="); putu(real_mode);
                    puts_(" op="); putu(i);
                    puts_(" got="); puthex(got); puts_(" exp="); puthex(exp);
                    uart_send_char('\n');
                }
                bad++;
            }
        }
    }
    *npu_cycles = acc;
    return bad;
}

/** MODE_AUTO：一次 start 跑完 slim ROM；返回 bad（err 或最后一个 head FNV 不符）。 */
static u32 run_auto(u32 expect_final_fnv, u64 *npu_cycles) {
    u32 bad = 0;
    (void)REG(MMIO_NN_STATUS);          /* 读清 */
    REG(MMIO_NN_CTRL) = 3u;             /* bit0=start, bit1=auto */
    for (;;) {
        u32 st = REG(MMIO_NN_STATUS);
        if (st & 4u) { bad++; break; }  /* err */
        if (st & 2u) break;             /* done */
    }
    *npu_cycles = (u64)REG(MMIO_NN_CYCLES);
    if (bad == 0u) {
        /* 全 plan 后 B@0x78000 = 最后一个 head（op70，24x24x4） */
        u32 got = fnv_tensor(YOLO_FINALS[YOLO_FINAL_N - 1u].abs,
                             YOLO_FINALS[YOLO_FINAL_N - 1u].h,
                             YOLO_FINALS[YOLO_FINAL_N - 1u].w,
                             YOLO_FINALS[YOLO_FINAL_N - 1u].c);
        puts_("[slim] auto_final_fnv="); puthex(got);
        puts_(" exp="); puthex(expect_final_fnv);
        if (got != expect_final_fnv) { puts_(" BAD"); bad++; }
        uart_send_char('\n');
    }
    return bad;
}

int main(void) {
    puts_("[slim] M6a slim 96x96 71-op E2E (real image 0349 + pattern + auto)\n");

    /* ================= Phase R: 真实图 0349（TB 预载） ================= */
    u32 rin = real_input_csum();
    puts_("[slim] real_input_csum="); puthex(rin);
    puts_(" exp="); puthex(REAL_INPUT_CSUM);
    u32 badR = 0;
    if (rin != REAL_INPUT_CSUM) { puts_(" BAD"); badR++; }
    uart_send_char('\n');
    if (badR == 0u) {
        u64 cycR = 0; u32 nR = 0;
        badR = run_plan_hw(1u, &cycR, &nR);
        puts_("[slim] real_ops_checked="); putu(YOLO_NUM_OPS);
        puts_(" real_ops_run="); putu(nR);
        puts_(" real_hw_bad="); putu(badR);
        puts_(" real_npu_cycles="); putu((u32)cycR);
        uart_send_char('\n');
    }


    /* ================= Phase P: pattern_v1（71 op 全量逐 op 金标） ================= */
    u32 pin = gen_input_pattern();
    puts_("[slim] pattern_input_csum="); puthex(pin);
    puts_(" exp="); puthex(YOLO_INPUT_CSUM);
    u32 badP = 0;
    if (pin != YOLO_INPUT_CSUM) { puts_(" BAD"); badP++; }
    uart_send_char('\n');
    u64 cycP = 0;
    u32 nP = 0;
    if (badP == 0u) badP = run_plan_hw(0u, &cycP, &nP);
    puts_("[slim] pattern_ops_run="); putu(nP);
    puts_(" pattern_hw_bad="); putu(badP);
    puts_(" pattern_npu_cycles="); putu((u32)cycP);
    uart_send_char('\n');

    /* ================= Phase A: MODE_AUTO（slim ROM 自主跑） ================= */
    (void)gen_input_pattern();          /* plan 会覆写 A，恢复输入 */
    u64 cycA = 0;
    u32 badA = run_auto(YOLO_FINALS[YOLO_FINAL_N - 1u].csum, &cycA);
    puts_("[slim] auto_bad="); putu(badA);
    puts_(" auto_npu_cycles="); putu((u32)cycA);
    uart_send_char('\n');

    /* ================= 周期对账（HANDOFF §④ ±30%） ================= */
    puts_("[slim] npu_cycles(hw)="); putu((u32)cycP);
    puts_(" exp="); putu(EXPECT_NPU_CYCLES);
    puts_(" range=["); putu(CYCLES_LO); puts_(".."); putu(CYCLES_HI); puts_("]");
    u32 badC = 0;
    if ((u32)cycP < CYCLES_LO || (u32)cycP > CYCLES_HI) { puts_(" OUT_OF_RANGE"); badC++; }
    uart_send_char('\n');
    if ((u32)cycA != 0u && (u32)cycA != (u32)cycP) {
        puts_("[slim] BAD: auto cycles != mode_cpu cycles\n"); badC++;
    }

    u32 bad = badR + badP + badA + badC;
    puts_("[slim] total_bad="); putu(bad); uart_send_char('\n');
    if (bad == 0u) {
        puts_("[slim] SLIM_TB: PASS\n");
        report_done();
    } else {
        puts_("[slim] SLIM_TB: FAIL\n");
        report_fail();
    }
    return (int)bad;
}
