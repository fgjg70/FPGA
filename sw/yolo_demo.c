/* ============================================================================
 * yolo_demo.c — 简单 YOLO (YOLO-Fastest v1.1, int8 PTQ) 在 RV32 SoC 上的部署
 * ----------------------------------------------------------------------------
 * 两种构建模式（同一份源码）：
 *   普通:    CPU 软件基线 + 硬件加速 两遍跑，逐 op 比 checksum，测加速比  → 上板用
 *   -DYOLO_HW_ONLY: 只跑硬件加速一遍（省 CPU 的 2 亿拍仿真时间）            → ModelSim 用
 *
 * 输入图：**确定性合成图**（公式见 CONTRACT §10.1 input.gen），C 与 golden 用同一公式，
 *   所以不需要把 49KB 图像存进 BRAM/dmem，也解决了"两遍运行要恢复初始图"的问题
 *   （每遍开始 CPU 重新生成）。真实图片是后续的板级扩展（UART 下发），不在本程序里。
 *
 * 判据（全部机器判定，不接受肉眼）：
 *   - 输入图 checksum == plan.input.csum
 *   - 每个 op 输出（真实通道、紧凑布局、逻辑序）的 FNV-1a == plan 里的 golden csum
 *   - 硬件路径逐 op mismatch 计数必须为 0（这就是"位精确"的证据）
 *   - 软件基线路径同样逐 op 比对（证明 CPU 参考实现也符合 golden，加速比才有意义）
 *   - 加速比 = sw_cycles / hw_cycles（两个都是 MMIO 周期计数器实测）
 *
 * 地址/布局常量**全部来自自动生成的 sw/yolo_plan.h**（tools/nn_gen_sw.py 从
 * rv32_pkg.sv / nn_pkg.sv / plan.json 抄出）—— 禁止在本文件手写 NN 窗口地址。
 * ==========================================================================*/

#include <stddef.h>
#include "yolo_plan.h"

typedef unsigned char      u8;
typedef signed char        s8;
typedef unsigned short     u16;
typedef unsigned int       u32;
typedef signed int         s32;
typedef unsigned long long u64;

/* ---- 外设 (portme.c 提供) ---- */
extern void uart_send_char(char c);
extern void report_done(void);
extern void report_fail(void);

/* ---- NN 窗口: CPU 通过 core 的 nn_* 专用端口访问 (与 dmem 同口径, 1 拍寄存读) ---- */
#define NN_WIN ((volatile u8 *)YOLO_NN_BASE)

static inline u8  rd8 (u32 off) { return NN_WIN[off]; }
static inline void wr8(u32 off, u8 v) { NN_WIN[off] = v; }
static inline u32 rd32(u32 off) { return *(volatile u32 *)(NN_WIN + off); }
static inline void wr32(u32 off, u32 v) { *(volatile u32 *)(NN_WIN + off) = v; }
static inline s32 rd16s(u32 off) { return (s32)(short)((u32)rd8(off) | ((u32)rd8(off + 1) << 8)); }

/* ---- MMIO ---- */
#define REG(a)  (*(volatile u32 *)(u32)(a))
static inline u64 rd_cycles(void) {
    u32 lo, hi, hi2;
    do { hi = REG(MMIO_CYCLE_HI); lo = REG(MMIO_CYCLE_LO); hi2 = REG(MMIO_CYCLE_HI); }
    while (hi != hi2);
    return ((u64)hi << 32) | (u64)lo;
}

/* ---- UART 打印 ---- */
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

/* ---- FNV-1a (与 golden/plan 相同口径) ---- */
static inline u32 fnv_byte(u32 h, u8 b) { h ^= (u32)b; h *= 16777619u; return h; }

/** 对一个紧凑张量 (H,W,C 真实通道, pixel stride = ceil(C/8)*8) 求 FNV-1a，
 *  下标序 = w-major (y,x,c)，即 golden 的"逻辑序"。 */
static u32 fnv_tensor(u32 abs, u32 h, u32 w, u32 c) {
    u32 c8 = (c + 7u) & ~7u;
    u32 hsh = 2166136261u;
    for (u32 y = 0; y < h; y++) {
        u32 row = abs + y * w * c8;
        for (u32 x = 0; x < w; x++) {
            u32 o = row + x * c8;
            for (u32 i = 0; i < c; i++) hsh = fnv_byte(hsh, rd8(o + i));
        }
    }
    return hsh;
}

/** 对 packed 张量 (H,W,C, stride=C) 求 FNV-1a（输入图用，CONTRACT §10.1）。 */
static u32 fnv_tensor_packed(u32 abs, u32 h, u32 w, u32 c) {
    u32 hsh = 2166136261u;
    for (u32 i = 0; i < h * w * c; i++) hsh = fnv_byte(hsh, rd8(abs + i));
    return hsh;
}

/* ---- 确定性输入图 (CONTRACT §10.1; C 与 Python 必须逐字节一致) ---- */
/* v0.3.1: 输入按 **packed** 存储 (stride = ic, 无 8 通道 padding)。
 * 原因: 128x128x3 按 8 通道分块要 128KB, 放不进 64KB 的 A 缓冲; packed 只需 49,152B。
 * 第 0 层因此由 CPU 执行 (kind = cpu_conv0)。 */
static u32 gen_input(void) {
    for (u32 y = 0; y < YOLO_INPUT_H; y++)
        for (u32 x = 0; x < YOLO_INPUT_W; x++) {
            u32 o = YOLO_INPUT_ABS + (y * YOLO_INPUT_W + x) * YOLO_INPUT_STRIDE;
            for (u32 c = 0; c < YOLO_INPUT_C; c++) {
                u8 q = (u8)((x * 13u + y * 7u + c * 29u + YOLO_INPUT_GEN_SEED) & 0xFFu);
                wr8(o + c, q);
            }
        }
    return fnv_tensor_packed(YOLO_INPUT_ABS, YOLO_INPUT_H, YOLO_INPUT_W, YOLO_INPUT_C);
}

/* ---- 输出尺寸 (与 darknet/plan 同式) ---- */
static inline u32 out_dim(u32 in, u32 k, u32 st, u32 pad) {
    return (in + 2u * pad - k) / st + 1u;
}
static inline s32 clamp8(s32 v) { return v < -128 ? -128 : (v > 127 ? 127 : v); }

/* ---- requant: 与 CONTRACT §5 v0.3 位精确一致 (int16 M_pos + 现算 M_neg, int64 中间, floor 右移) ----
 * Q 区每层变长布局 (CONTRACT §7):
 *   +0            : bias_adj[OC_pad]  int32
 *   +4*OC_pad     : M_pos[OC_pad]     int16
 *   +6*OC_pad     : tail[16]: [0]=zp_out [1]=zp_in [2]=leaky_en [3]=SHIFT
 */
static inline s8 requant(s32 acc, u32 qoff, u32 ocp, u32 oc, s32 zp_out) {
    s32 mpos = rd16s(qoff + 4u * ocp + 2u * oc);
    s32 m    = (acc >= 0) ? mpos : ((mpos * 3277 + 16384) >> 15);   /* M_neg 现算 */
    s32 sh   = (s32)(s8)rd8(qoff + 6u * ocp + 3u);
    long long y = ((long long)acc * (long long)m) >> sh;             /* 算术右移 = floor */
    return (s8)clamp8((s32)y + zp_out);
}

/* ==========================================================================
 * 软件基线实现 (CPU 逐 MAC；就是"没有加速器时"的真实代价)
 * ==========================================================================*/
/**
 * 软件卷积实现。
 *   kind=YK_CONV / YK_DWCONV: 输入按 8 通道分块 (a_stride = ceil(ic/8)*8)
 *   kind=YK_CPU_CONV0       : 输入是 **packed** 3 字节/像素 (a_stride = ic)
 * 权重始终按 §6 的 IC_pad=8 布局。
 */
static void sw_conv(const yolo_op_t *o) {
    const u32 ic = o->ic, oc = o->oc, k = o->k, st = o->stride, pad = o->pad;
    const u32 ih = o->ih, iw = o->iw;
    const u32 oh = out_dim(ih, k, st, pad), ow = out_dim(iw, k, st, pad);
    const u32 ic8 = (ic + 7u) & ~7u, oc8 = (oc + 7u) & ~7u;
    const u32 a_stride = (o->kind == YK_CPU_CONV0) ? ic : ic8;   /* v0.3.1 */
    const u32 qoff = o->qoff, woff = o->woff, src = o->src, dst = o->dst;
    const s32 zpi = (s32)(s8)rd8(qoff + 6u * oc8 + 1u);
    const s32 zpo = (s32)(s8)rd8(qoff + 6u * oc8 + 0u);
    const int dw = (o->flags & YF_DEPTHWISE) != 0;

    for (u32 oy = 0; oy < oh; oy++) {
        for (u32 ox = 0; ox < ow; ox++) {
            u32 dbase = dst + (oy * ow + ox) * oc8;
            if (dw) {
                for (u32 ch = 0; ch < oc; ch++) {
                    s32 acc = (s32)rd32(qoff + 4u * ch);
                    for (u32 ky = 0; ky < k; ky++) {
                        s32 iy = (s32)(oy * st + ky) - (s32)pad;
                        for (u32 kx = 0; kx < k; kx++) {
                            s32 ix = (s32)(ox * st + kx) - (s32)pad;
                            u32 tap = ky * k + kx;
                            s32 a;
                            if (iy < 0 || ix < 0 || iy >= (s32)ih || ix >= (s32)iw) a = zpi;
                            else a = (s32)(s8)rd8(src + ((u32)iy * iw + (u32)ix) * a_stride + ch);
                            acc += a * (s32)(s8)rd8(woff + tap * oc8 + ch);
                        }
                    }
                    wr8(dbase + ch, (u8)requant(acc, qoff, oc8, ch, zpo));
                }
            } else {
                for (u32 oc0 = 0; oc0 < oc; oc0++) {
                    s32 acc = (s32)rd32(qoff + 4u * oc0);
                    for (u32 ky = 0; ky < k; ky++) {
                        s32 iy = (s32)(oy * st + ky) - (s32)pad;
                        for (u32 kx = 0; kx < k; kx++) {
                            s32 ix = (s32)(ox * st + kx) - (s32)pad;
                            u32 tap = ky * k + kx;
                            u32 wbase = woff + (tap * ic8) * oc8 + oc0;
                            if (iy < 0 || ix < 0 || iy >= (s32)ih || ix >= (s32)iw) {
                                for (u32 ic0 = 0; ic0 < ic; ic0++)
                                    acc += zpi * (s32)(s8)rd8(wbase + ic0 * oc8);
                            } else {
                                u32 abase = src + ((u32)iy * iw + (u32)ix) * a_stride;
                                for (u32 ic0 = 0; ic0 < ic; ic0++)
                                    acc += (s32)(s8)rd8(abase + ic0) * (s32)(s8)rd8(wbase + ic0 * oc8);
                            }
                        }
                    }
                    wr8(dbase + oc0, (u8)requant(acc, qoff, oc8, oc0, zpo));
                }
            }
        }
    }
}

static void sw_pool(const yolo_op_t *o) {
    const u32 c = o->ic, k = o->k, st = o->stride, pad = o->pad;
    const u32 ih = o->ih, iw = o->iw;
    const u32 oh = out_dim(ih, k, st, pad), ow = out_dim(iw, k, st, pad);
    const u32 c8 = (c + 7u) & ~7u;
    for (u32 oy = 0; oy < oh; oy++)
        for (u32 ox = 0; ox < ow; ox++) {
            u32 dbase = o->dst + (oy * ow + ox) * c8;
            for (u32 ch = 0; ch < c; ch++) {
                s32 best = -128;
                for (u32 ky = 0; ky < k; ky++) {
                    s32 iy = (s32)(oy * st + ky) - (s32)pad;
                    if (iy < 0 || iy >= (s32)ih) continue;
                    for (u32 kx = 0; kx < k; kx++) {
                        s32 ix = (s32)(ox * st + kx) - (s32)pad;
                        if (ix < 0 || ix >= (s32)iw) continue;
                        s32 a = (s32)(s8)rd8(o->src + ((u32)iy * iw + (u32)ix) * c8 + ch);
                        if (a > best) best = a;
                    }
                }
                wr8(dbase + ch, (u8)(s8)best);
            }
        }
}

static void sw_upsample(const yolo_op_t *o) {
    const u32 c = o->ic, ih = o->ih, iw = o->iw;
    const u32 c8 = (c + 7u) & ~7u;
    for (u32 y = 0; y < ih * 2u; y++)
        for (u32 x = 0; x < iw * 2u; x++) {
            u32 s = o->src + ((y >> 1) * iw + (x >> 1)) * c8;
            u32 d = o->dst + (y * iw * 2u + x) * c8;
            for (u32 ch = 0; ch < c8; ch++) wr8(d + ch, rd8(s + ch));
        }
}

static void sw_add(const yolo_op_t *o) {
    const u32 c = o->ic, ih = o->ih, iw = o->iw;
    const u32 c8 = (c + 7u) & ~7u;
    for (u32 y = 0; y < ih * iw; y++) {
        u32 so = o->src + y * c8, dof = o->dst + y * c8;
        for (u32 ch = 0; ch < c8; ch++) {
            s32 v = (s32)(s8)rd8(so + ch) + (s32)(s8)rd8(dof + ch);
            wr8(dof + ch, (u8)(s8)clamp8(v));
        }
    }
}

/* ==========================================================================
 * v0.5: shortcut residual add 改由 **CPU** 执行（per-tensor 源 requant）
 * --------------------------------------------------------------------------
 * 为什么不在引擎里做: raw-add 要求 branch 张量与 sum 张量共享同一组 (s_a, zp_a)，
 * 而 branch 的值域 ±1.5 远小于 sum 的 ±19 → branch 只用 ~20 个量化台阶，这是
 * int8 逐层 cos 上不去的根因（model-report §6）。把 add 放到 CPU、并用 per-tensor
 * 源域→目标域的 requant 标量，branch 就能用自己的 scale，精度问题解除；
 * 引擎的 ADD op 保留但不再被计划使用（未来若要回硬件，需要给 add 增加同类标量）。
 *
 * 整数公式（CONTRACT §11 v0.5；golden/C 必须逐位一致，int64 中间）：
 *   R = round(s_src/s_dst * 2^KADD);  out = clamp(q_d + (((q_s - zp_s)*R) >> KADD), -128, 127)
 *   ⚠ 不加 zp_d —— q_d 本身已含目标 zero-point；增量是"源域差值"映射到目标域。
 * 字段来源: aux0=R, aux1=KADD, aux2=zp_s(符号扩展存放), 尺寸 ih/iw/ic。
 * ==========================================================================*/
static void sw_cpu_add(const yolo_op_t *o) {
    const s32 R   = (s32)o->aux0;
    const s32 K   = (s32)o->aux1;
    const s32 zps = (s32)o->aux2;
    const u32 c = o->ic, ih = o->ih, iw = o->iw;
    const u32 c8 = (c + 7u) & ~7u;
    for (u32 y = 0; y < ih; y++)
        for (u32 x = 0; x < iw; x++) {
            u32 so  = o->src + (y * iw + x) * c8;
            u32 dof = o->dst + (y * iw + x) * c8;
            for (u32 ch = 0; ch < c; ch++) {
                s32 qs = (s32)(s8)rd8(so + ch);
                s32 qd = (s32)(s8)rd8(dof + ch);
                s32 d  = ((qs - zps) * R) >> K;     /* 算术右移 = floor */
                wr8(dof + ch, (u8)(s8)clamp8(qd + d));
            }
        }
}

/* cpu_concat / cpu_copy: 把若干紧凑张量按通道拼到目标紧凑张量 */
static void sw_cat(const yolo_op_t *o) {
    const yolo_cat_t *ct = &YOLO_CATS[o->src];     /* op.src = 表索引 */
    u32 nsrc = ct->nsrc, oc = ct->oc;
    u32 oc8 = (oc + 7u) & ~7u;
    /* 目标张量尺寸: op.ih/op.iw (生成器为 cpu_concat 填了目标 H/W) */
    u32 oh = o->ih, ow = o->iw;
    u32 coff = 0;
    for (u32 s = 0; s < nsrc; s++) {
        const yolo_src_t *sp = &YOLO_CAT_SRC[ct->first + s];
        u32 sc = sp->c, sc8 = (sc + 7u) & ~7u;
        for (u32 y = 0; y < oh; y++)
            for (u32 x = 0; x < ow; x++) {
                u32 so = sp->abs + (y * ow + x) * sc8;
                u32 dof = ct->dst + (y * ow + x) * oc8 + coff;
                for (u32 ch = 0; ch < sc; ch++) wr8(dof + ch, rd8(so + ch));
            }
        coff += sc;
    }
}

/* ==========================================================================
 * 硬件路径: 写描述符 -> start -> 轮询 -> 读 CYCLES
 * ==========================================================================*/
/* ---- 硬件 op 码映射 ----
 * 【2026-10-31 真 bug】C 侧 kind 枚举 (0=conv,1=dwconv,2=pool,3=upsample,4=add) 与
 * CONTRACT §4 的 NN_OP 编码 (**0=conv/dwconv, 1=maxpool, 2=copy/upsample, 3=add**) 不是同一个表!
 * 首版直接把 o->kind 写进 MMIO_NN_OP → op2(dwconv) 被引擎当成 maxpool 执行，
 * 从 op2 起 106 个 op 全部 cascade mismatch (t-accel 用"op2 输入按 maxpool 算"的 FNV
 * 反推 = 现场 got 0xedb78029 精确命中)。depthwise 由 NN_FLAGS.bit0 表达，不需要单独 op 码。
 */
static u32 hw_op_code(const yolo_op_t *o) {
    switch (o->kind) {
        case YK_CONV:
        case YK_DWCONV:   return 0u;   /* NN_OP_CONV (+ flags.DEPTHWISE) */
        case YK_POOL:     return 1u;   /* NN_OP_POOL  */
        case YK_UPSAMPLE: return 2u;   /* NN_OP_COPY  */
        default:          return 3u;   /* YK_ADD -> NN_OP_ADD */
    }
}

/** 硬件执行累计周期 (= 所有 NN_CYCLES 之和)。用于把"NPU 纯计算时间"与
 *  "整个硬件遍含 CPU conv0/搬运/checksum 的时间"分开报告 —— 否则加速比会被
 *  debug 用的 checksum 开销稀释，口径不诚实。 */
static u64 g_npu_cycles = 0;

static u32 hw_run(const yolo_op_t *o) {
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
    (void)REG(MMIO_NN_STATUS);              /* 读清 done/err */
    REG(MMIO_NN_CTRL) = 1u;                 /* start */
    u32 guard = 0;
    for (;;) {
        u32 st = REG(MMIO_NN_STATUS);
        if (st & 4u) { puts_("  [hw] ERR status="); puthex(st); uart_send_char('\n'); return 0xFFFFFFFFu; }
        if (st & 2u) break;                 /* done */
        if (++guard > 200000000u) { puts_("  [hw] TIMEOUT\n"); return 0xFFFFFFFEu; }
    }
    u32 cyc = REG(MMIO_NN_CYCLES);
    g_npu_cycles += cyc;
    return cyc;
}

/** 一个 op 的期望输出张量 (h,w,c) —— 用于 checksum */
static void op_out_shape(const yolo_op_t *o, u32 *h, u32 *w, u32 *c) {
    switch (o->kind) {
        case YK_CONV:
        case YK_CPU_CONV0:                                    /* v0.3.1: 第 0 层 CPU 执行 */
        case YK_DWCONV:
            *h = out_dim(o->ih, o->k, o->stride, o->pad);
            *w = out_dim(o->iw, o->k, o->stride, o->pad);
            *c = o->oc; break;
        case YK_POOL:
            *h = out_dim(o->ih, o->k, o->stride, o->pad);
            *w = out_dim(o->iw, o->k, o->stride, o->pad);
            *c = o->ic; break;
        case YK_UPSAMPLE: *h = o->ih * 2u; *w = o->iw * 2u; *c = o->ic; break;
        case YK_ADD:      *h = o->ih;      *w = o->iw;      *c = o->ic; break;
        case YK_CPU_ADD:  *h = o->ih;      *w = o->iw;      *c = o->ic; break;
        default:          *h = o->ih;      *w = o->iw;      *c = o->oc; break;  /* cat/copy: 目标张量 */
    }
}

/** 跑一遍计划；hw=1 走加速器(仅支持的 kind)，hw=0 全软件。返回 mismatch 数。 */
static u32 run_plan(int hw, u64 *cycles_out, u32 *first_bad) {
    u32 bad = 0;
    u64 t0 = rd_cycles();
    for (u32 i = 0; i < YOLO_NUM_OPS; i++) {
        const yolo_op_t *o = &YOLO_OPS[i];
        if (hw) {
            switch (o->kind) {
                case YK_CONV:
                case YK_DWCONV:
                case YK_POOL:
                case YK_UPSAMPLE:
                case YK_ADD:
                    (void)hw_run(o);
                    break;
                case YK_CPU_CONV0:
                    sw_conv(o);             /* v0.3.1: 第 0 层没有引擎路径, 永远 CPU */
                    break;
                case YK_CPU_ADD:
                    sw_cpu_add(o);          /* v0.5: shortcut add 由 CPU 做 (精度修复) */
                    break;
                default:
                    sw_cat(o);              /* cpu_concat / cpu_copy 仍由 CPU 做 */
                    break;
            }
        } else {
            switch (o->kind) {
                case YK_CONV: case YK_DWCONV: case YK_CPU_CONV0: sw_conv(o); break;
                case YK_POOL: sw_pool(o); break;
                case YK_UPSAMPLE: sw_upsample(o); break;
                case YK_ADD: sw_add(o); break;
                case YK_CPU_ADD: sw_cpu_add(o); break;
                default: sw_cat(o); break;
            }
        }
        /* ---- [诊断] 可选: 打印某个 op 的输入/输出前 32 字节 (与 golden .hex 对照) ----
         * 编译时 -DYOLO_DBG_OP=<n> 打开; 默认关闭 (不影响正式判据)。
         * 用途: E2E 定位"哪个字节错了" —— 比如 op2 的差异只在边界 => padding 问题,
         *       全片差异 => 权重/量化/地址问题。 */
#ifdef YOLO_DBG_OP
        if ((int)i == YOLO_DBG_OP) {
            puts_("  [dbg] op="); putu(i);
            puts_(" src+0: ");
            for (u32 k = 0; k < 16u; k++) { puthex((u32)rd8(o->src + k)); uart_send_char(' '); }
            puts_(" dst+0: ");
            for (u32 k = 0; k < 16u; k++) { puthex((u32)rd8(o->dst + k)); uart_send_char(' '); }
            puts_(" dst+mid: ");
            for (u32 k = 0; k < 8u; k++) { puthex((u32)rd8(o->dst + 16384u + k)); uart_send_char(' '); }
            uart_send_char('\n');
        }
#endif
        /* 逐 op 比对 golden checksum */
        u32 gh, gw, gc;
        op_out_shape(o, &gh, &gw, &gc);
        u32 got = fnv_tensor(o->dst, gh, gw, gc);
        if (got != o->csum) {
            if (bad == 0 && first_bad) *first_bad = i;
            bad++;
            if (bad <= 8) {
                puts_("  [bad] op="); putu(i);
                puts_(" kind="); putu(o->kind);
                puts_(" got="); puthex(got);
                puts_(" exp="); puthex(o->csum);
                uart_send_char('\n');
            }
        }
    }
    *cycles_out = rd_cycles() - t0;
    return bad;
}

int main(void) {
    puts_("\n[yolo] YOLO-Fastest v1.1 int8 (Xilinx A100T NPU)\n");
    puts_("[yolo] ops="); putu(YOLO_NUM_OPS);
    puts_(" in="); putu(YOLO_INPUT_H); uart_send_char('x');
    putu(YOLO_INPUT_W); uart_send_char('x'); putu(YOLO_INPUT_C);
    uart_send_char('\n');

    /* ---- 0. 输入图自检 ---- */
    u32 ic_sum = gen_input();
    puts_("[yolo] input_csum="); puthex(ic_sum);
    puts_(" exp="); puthex(YOLO_INPUT_CSUM);
    puts_((ic_sum == YOLO_INPUT_CSUM) ? " OK" : " MISMATCH");
    uart_send_char('\n');

    u64 hw_cycles = 0, sw_cycles = 0;
    u32 first_bad = 0;
    u32 hw_bad;
    u32 sw_bad = 0xFFFFFFFFu;   /* YOLO_HW_ONLY 时保持哨兵值, 不参与判定 */

#ifndef YOLO_HW_ONLY
    /* ---- 1. 软件基线 (CPU 逐 MAC) ---- */
    (void)gen_input();                       /* 恢复初始图 (上一轮可能被写过) */
    sw_bad = run_plan(0, &sw_cycles, &first_bad);
    puts_("[yolo] sw_bad="); putu(sw_bad);
    puts_(" sw_cycles="); putu((u32)sw_cycles); uart_send_char('\n');
    (void)gen_input();                       /* 恢复初始图, 准备硬件遍 */
#endif

    /* ---- 2. 硬件加速 ---- */
    hw_bad = run_plan(1, &hw_cycles, &first_bad);
    puts_("[yolo] hw_bad="); putu(hw_bad);
    puts_(" hw_cycles="); putu((u32)hw_cycles);
    /* npu_cycles = 所有 NN_CYCLES 之和 = 引擎纯计算时间 (不含 CPU conv0/搬运/checksum)。
     * 报告加速比时这个数才是"NPU vs CPU 卷积"的公平分子; hw_cycles 是含 debug 开销的
     * 整个硬件遍, 两个都打印出来, 口径自己会说话。 */
    puts_(" npu_cycles="); putu((u32)g_npu_cycles);
    if (hw_bad) { puts_(" first_bad_op="); putu(first_bad); }
    uart_send_char('\n');

#ifndef YOLO_HW_ONLY
    if (sw_cycles > 0) {
        u32 x100 = (u32)((sw_cycles * 100ull) / (hw_cycles ? hw_cycles : 1ull));
        puts_("[yolo] speedup_x100="); putu(x100);
        puts_(" ("); putu(x100 / 100u); uart_send_char('.'); putu(x100 % 100u);
        puts_("x)\n");
        if (g_npu_cycles > 0) {
            u32 n100 = (u32)((sw_cycles * 100ull) / g_npu_cycles);
            puts_("[yolo] speedup_npu_x100="); putu(n100);
            puts_(" ("); putu(n100 / 100u); uart_send_char('.'); putu(n100 % 100u);
            puts_("x, sw vs NPU-only)\n");
        }
    }
    int ok = (ic_sum == YOLO_INPUT_CSUM) && (sw_bad == 0) && (hw_bad == 0);
#else
    int ok = (ic_sum == YOLO_INPUT_CSUM) && (hw_bad == 0);
#endif
    puts_(ok ? "[yolo] RESULT : PASS\n" : "[yolo] RESULT : FAIL\n");
    if (ok) report_done(); else report_fail();
    return 0;
}
