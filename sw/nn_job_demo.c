/* ============================================================================
 * nn_job_demo.c — CPU-NPU 解耦（S1 单时钟）job 模式最小 demo（task-13）
 * ----------------------------------------------------------------------------
 * 目标：验证 **job 级接口**（设计见 results/bottlecap/reports/CPU-NPU-DECOUPLE.md §4）：
 *   CPU 只写 "输入/输出/模型/帧号 + doorbell"，NPU 用 nn_seq 自主跑完整 ROM，
 *   完成后置 done/err/cycles + 写 2KB 结果邮箱；CPU 读邮箱/ACK 后能再起下一 job。
 *
 * 判据（全部机器判定，TB 只认 tohost + 日志）：
 *   ① doorbell 后 NPU 自主跑完整 ROM（done=1，cycles>0；期望 == 1,191,020）
 *   ② done/err/cycles 正确（err=0；frame_no 回显；cycles 与 YOLO 口径对账）
 *   ③ 结果邮箱：magic/frame/model/len 正确；payload 1024B 与 A/B 窗口同地址
 *      **逐字节一致**；最终两个检测头张量的 FNV == golden（yolo_plan.h 的 YOLO_FINALS，
 *      即 MODE_CPU/MODE_AUTO 已证明逐位一致的同一 golden）
 *   ④ ACK 后再起第二个 job 并成功完成
 *   ⑤ job A 运行中重复写 doorbell -> 被忽略且 NN_JOB_DROP_CNT 递增
 *
 * 地址约定：全部来自 sw/yolo_plan.h（自动生成，禁止手写 NN 窗口地址）；
 *   job 寄存器地址优先用生成的 MMIO_NN_JOB_*，头文件暂时没有就用下面的 fallback
 *   （Lead 把常量加进 rv32_pkg.sv 后重生成头文件即自动接管）。
 *
 * 构建：python tools/build_sw.py sw/nn_job_demo.c sw/portme.c -O -O2 --march rv32im \
 *                  -o sim/prog/nn_job_demo.hex
 * ==========================================================================*/

#include <stddef.h>
#include "yolo_plan.h"

typedef unsigned char      u8;
typedef signed char        s8;
typedef unsigned short     u16;
typedef unsigned int       u32;
typedef signed int         s32;

extern void uart_send_char(char c);
extern void report_done(void);
extern void report_fail(void);

/* ---- NN 窗口（CPU 数据窗口；与 yolo_demo.c 同口径：1 拍寄存读） ---- */
#define NN_WIN ((volatile u8 *)YOLO_NN_BASE)

static inline u8  rd8 (u32 off) { return NN_WIN[off]; }
static inline u32 rd32(u32 off) { return *(volatile u32 *)(NN_WIN + off); }

/* ---- MMIO ---- */
#define REG(a)  (*(volatile u32 *)(u32)(a))

/* ---- job 级 MMIO 寄存器（0xA000_0150..，见 CPU-NPU-DECOUPLE.md §4.2） ---- */
#ifndef MMIO_NN_JOB_ID
#define MMIO_NN_JOB_ID       0xA0000150u
#define MMIO_NN_JOB_STATUS   0xA0000154u
#define MMIO_NN_JOB_FRAME_NO 0xA0000158u
#define MMIO_NN_JOB_CYCLES   0xA000015Cu
#define MMIO_NN_JOB_IN_ADDR  0xA0000160u
#define MMIO_NN_JOB_OUT_ADDR 0xA0000164u
#define MMIO_NN_JOB_MODEL    0xA0000168u
#define MMIO_NN_JOB_FRAME    0xA000016Cu
#define MMIO_NN_JOB_DOORBELL 0xA0000170u
#define MMIO_NN_JOB_ACK      0xA0000174u
#define MMIO_NN_JOB_ERR_CODE 0xA0000178u
#define MMIO_NN_JOB_LEN      0xA000017Cu
#define MMIO_NN_JOB_DONE_CNT 0xA0000180u
#define MMIO_NN_JOB_DROP_CNT 0xA0000184u
#endif

/* JOB_STATUS 位定义（与 RTL 一致） */
#define JOB_ST_BUSY   0x00000001u
#define JOB_ST_DONE   0x00000002u
#define JOB_ST_ERR    0x00000004u
#define JOB_ST_PEND   0x00000008u
#define JOB_ST_RDY    0x00000010u   /* model_ready */
#define JOB_ST_TMO    0x00000040u
#define JOB_ST_MBVAL  0x00000080u

/* 结果邮箱（映射在 NN 窗口偏移 0x000..0x7FF；设计 §4.3） */
#define NN_MB_OFF        0x00000u
#define NN_MB_MAGIC      0x00u
#define NN_MB_FRAME      0x04u
#define NN_MB_MODEL      0x08u
#define NN_MB_CYCLES     0x0Cu
#define NN_MB_ERR        0x10u
#define NN_MB_SRC        0x14u
#define NN_MB_LEN        0x18u
#define NN_MB_RSVD       0x1Cu
#define NN_MB_PAYLOAD    0x20u
#define NN_MB_MAGIC_VAL  0x4E505552u   /* "NPUR" */

/* S1 本 demo 参数 */
#define JOB_FRAME_NO_VAL 0x00001234u
#define JOB_MODEL_VAL    0u            /* 0 = YOLO-C128（当前 ROM） */
#define JOB_MB_LEN       1024u         /* 邮箱 payload 字节数（>=4 的倍数） */
#define JOB_POLL_MAX     20000000u     /* 轮询上限（防死等；正常 < 1.3M 拍） */

static u32 g_bad = 0;

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
static void bad_line(const char *what) {
    puts_("[nnjob] BAD: "); puts_(what); uart_send_char('\n');
    g_bad++;
}

/* ---- FNV-1a（与 golden/plan 相同口径；复制自 yolo_demo.c 的独立整数实现） ---- */
static inline u32 fnv_byte(u32 h, u8 b) { h ^= (u32)b; h *= 16777619u; return h; }

/** 紧凑张量 (H,W,C 真实通道, pixel stride = ceil(C/8)*8) 的 FNV，逻辑序 y,x,c。 */
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

/* ---- 输入图写口 + packed FNV（必须在 gen_input 之前定义） ---- */
static inline void wr8_(u32 off, u8 v) { NN_WIN[off] = v; }

/** 对 packed 张量 (H,W,C, stride=C) 求 FNV-1a（输入图用，CONTRACT §10.1）。 */
static u32 fnv_tensor_packed(u32 abs, u32 h, u32 w, u32 c) {
    u32 hsh = 2166136261u;
    for (u32 i = 0; i < h * w * c; i++) hsh = fnv_byte(hsh, rd8(abs + i));
    return hsh;
}

/* ---- 确定性输入图（CONTRACT §10.1 pattern_v1；与 yolo_demo.c 逐字节一致） ---- */
static u32 gen_input(void) {
    for (u32 y = 0; y < YOLO_INPUT_H; y++)
        for (u32 x = 0; x < YOLO_INPUT_W; x++) {
            u32 o = YOLO_INPUT_ABS + (y * YOLO_INPUT_W + x) * YOLO_INPUT_STRIDE;
            for (u32 c = 0; c < YOLO_INPUT_C; c++) {
                u8 q = (u8)((x * 13u + y * 7u + c * 29u + YOLO_INPUT_GEN_SEED) & 0xFFu);
                wr8_(o + c, q);
            }
        }
    return fnv_tensor_packed(YOLO_INPUT_ABS, YOLO_INPUT_H, YOLO_INPUT_W, YOLO_INPUT_C);
}

/* ---- job 提交 / 等待 / ACK ---- */
static int job_submit(u32 in_addr, u32 out_addr, u32 model, u32 frame, u32 mb_len) {
    REG(MMIO_NN_JOB_IN_ADDR)  = in_addr;
    REG(MMIO_NN_JOB_OUT_ADDR) = out_addr;
    REG(MMIO_NN_JOB_MODEL)    = model;
    REG(MMIO_NN_JOB_FRAME)    = frame;
    REG(MMIO_NN_JOB_LEN)      = mb_len;
    REG(MMIO_NN_JOB_DOORBELL) = 1u;
    return 0;
}

/** 等 done/err；返回最终 status（超时返回 0xFFFFFFFF）。 */
static u32 job_wait_done(void) {
    for (u32 i = 0; i < JOB_POLL_MAX; i++) {
        u32 st = REG(MMIO_NN_JOB_STATUS);
        if (st & (JOB_ST_DONE | JOB_ST_ERR)) return st;
    }
    return 0xFFFFFFFFu;
}

static void job_ack(void) { REG(MMIO_NN_JOB_ACK) = 1u; }

/* ---- 结果校验：邮箱头 + payload 逐字节 + 最终张量 FNV vs golden ---- */
static void check_mailbox_and_result(u32 exp_out_addr, u32 mb_len) {
    u32 magic  = rd32(NN_MB_OFF + NN_MB_MAGIC);
    u32 frame  = rd32(NN_MB_OFF + NN_MB_FRAME);
    u32 model  = rd32(NN_MB_OFF + NN_MB_MODEL);
    u32 mcyc   = rd32(NN_MB_OFF + NN_MB_CYCLES);
    u32 merr   = rd32(NN_MB_OFF + NN_MB_ERR);
    u32 msrc   = rd32(NN_MB_OFF + NN_MB_SRC);
    u32 mlen   = rd32(NN_MB_OFF + NN_MB_LEN);
    u32 ncyc   = REG(MMIO_NN_JOB_CYCLES);
    u32 nfr    = REG(MMIO_NN_JOB_FRAME_NO);

    if (magic != NN_MB_MAGIC_VAL) bad_line("mailbox magic");
    if (frame != JOB_FRAME_NO_VAL) bad_line("mailbox frame_no");
    if ((model & 0xFFu) != JOB_MODEL_VAL) bad_line("mailbox model");
    if (merr != 0) bad_line("mailbox err");
    if (msrc != exp_out_addr) bad_line("mailbox src");
    if (mlen != mb_len) bad_line("mailbox len");
    if (mcyc == 0 || mcyc != ncyc) bad_line("mailbox cycles != JOB_CYCLES");
    if (nfr != JOB_FRAME_NO_VAL) bad_line("JOB_FRAME_NO echo");

    /* ③ payload 与 A/B 窗口同地址逐字节一致（= 与 MODE_AUTO 跑出的结果一致） */
    u32 mb_mismatch = 0;
    for (u32 i = 0; i < mb_len; i++) {
        if (rd8(NN_MB_OFF + NN_MB_PAYLOAD + i) != rd8(exp_out_addr + i)) mb_mismatch++;
    }
    if (mb_mismatch != 0) {
        puts_("[nnjob] mailbox payload mismatch="); putu(mb_mismatch);
        puts_(" of "); putu(mb_len); uart_send_char('\n');
        g_bad++;
    }

    /* ③ 最终张量 FNV vs golden（golden 来自 plan.json，与 MODE_CPU/MODE_AUTO 逐位一致） */
    for (u32 i = 0; i < YOLO_FINAL_N; i++) {
        u32 got = fnv_tensor(YOLO_FINALS[i].abs, YOLO_FINALS[i].h,
                             YOLO_FINALS[i].w, YOLO_FINALS[i].c);
        puts_("[nnjob] final"); putu(i); puts_(" fnv="); puthex(got);
        puts_(" exp="); puthex(YOLO_FINALS[i].csum);
        if (got != YOLO_FINALS[i].csum) { puts_(" BAD"); g_bad++; }
        uart_send_char('\n');
    }

    puts_("[nnjob] mailbox magic="); puthex(magic);
    puts_(" frame="); puthex(frame);
    puts_(" model="); putu(model & 0xFFu);
    puts_(" cycles="); putu(mcyc);
    puts_(" len="); putu(mlen); uart_send_char('\n');
}

int main(void) {
    puts_("[nnjob] NN job-mode demo (S1, single clock)\n");

    /* ---- 0. 身份 + 就绪 ---- */
    u32 id = REG(MMIO_NN_JOB_ID);
    u32 st0 = REG(MMIO_NN_JOB_STATUS);
    puts_("[nnjob] id="); puthex(id); puts_(" status0="); puthex(st0); uart_send_char('\n');

    /* ---- 1. 输入图（pattern_v1）放到 A 区；checksum 必须与 golden 一致 ---- */
    u32 ic_sum = gen_input();
    puts_("[nnjob] input_csum="); puthex(ic_sum);
    puts_(" exp="); puthex(YOLO_INPUT_CSUM);
    if (ic_sum != YOLO_INPUT_CSUM) { puts_(" BAD"); g_bad++; }
    uart_send_char('\n');

    /* ---- 2. job A：正确性 + 邮箱 + busy 丢门铃 ---- */
    u32 out_addr = YOLO_FINALS[0].abs;      /* 邮箱 payload 源 = 第一个检测头张量 */
    job_submit(YOLO_INPUT_ABS, out_addr, JOB_MODEL_VAL, JOB_FRAME_NO_VAL, JOB_MB_LEN);

    /* ⑤ 忙时重复 doorbell：等 busy 起来再敲一次，期望被丢弃 */
    u32 busy_seen = 0;
    for (u32 i = 0; i < 100000u; i++) {
        if (REG(MMIO_NN_JOB_STATUS) & JOB_ST_BUSY) { busy_seen = 1; break; }
    }
    if (!busy_seen) bad_line("busy never rose");
    u32 drop_before = REG(MMIO_NN_JOB_DROP_CNT);
    REG(MMIO_NN_JOB_DOORBELL) = 1u;         /* 应被忽略 */
    u32 drop_after = REG(MMIO_NN_JOB_DROP_CNT);
    if (drop_after != drop_before + 1u) bad_line("busy doorbell not dropped");
    puts_("[nnjob] drop_cnt="); putu(drop_after); uart_send_char('\n');

    u32 stA = job_wait_done();
    puts_("[nnjob] jobA status="); puthex(stA);
    puts_(" cycles="); putu(REG(MMIO_NN_JOB_CYCLES));
    puts_(" err_code="); puthex(REG(MMIO_NN_JOB_ERR_CODE)); uart_send_char('\n');
    if (stA == 0xFFFFFFFFu) bad_line("jobA timeout");
    if (!(stA & JOB_ST_DONE)) bad_line("jobA done bit");
    if (stA & JOB_ST_ERR) bad_line("jobA err bit");
    if (REG(MMIO_NN_JOB_ERR_CODE) != 0) bad_line("jobA err_code");
    if (REG(MMIO_NN_JOB_CYCLES) == 0) bad_line("jobA cycles==0");
    check_mailbox_and_result(out_addr, JOB_MB_LEN);
    job_ack();

    /* ---- 3. job B：ACK 后能起下一 job（重新生成输入，保证 A 区干净）---- */
    (void)gen_input();
    job_submit(YOLO_INPUT_ABS, out_addr, JOB_MODEL_VAL, JOB_FRAME_NO_VAL + 1u, 0u);
    u32 stB = job_wait_done();
    puts_("[nnjob] jobB status="); puthex(stB);
    puts_(" cycles="); putu(REG(MMIO_NN_JOB_CYCLES)); uart_send_char('\n');
    if (!(stB & JOB_ST_DONE)) bad_line("jobB done bit");
    if (stB & JOB_ST_ERR) bad_line("jobB err bit");
    if (REG(MMIO_NN_JOB_CYCLES) == 0) bad_line("jobB cycles==0");
    job_ack();

    u32 done_cnt = REG(MMIO_NN_JOB_DONE_CNT);
    puts_("[nnjob] jobs_done="); putu(done_cnt);
    puts_(" bad="); putu(g_bad); uart_send_char('\n');

    if (g_bad == 0) {
        puts_("[nnjob] RESULT : PASS\n");
        report_done();
    } else {
        puts_("[nnjob] RESULT : FAIL\n");
        report_fail();
    }
    return g_bad == 0 ? 0 : 1;
}
