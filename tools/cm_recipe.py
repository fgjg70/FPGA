#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cm_recipe.py -- CoreMark 编译配方的**单一事实来源** (Single Source of Truth)。

【为什么需要这个文件】(2026-11-03 新增, 修 PITFALLS R54)
本仓库里有**两个**脚本会编译 CoreMark 上板镜像, 而且**写同一个文件**:

    tools/build_sw.py  --all --with-hw   ->  sim/prog/cm_hw.hex
    tools/mk_cm_hw.py  <iters>           ->  sim/prog/cm_hw.hex   (同一个文件!)

在 2026-11-03 之前, 两处各自硬编码了一份编译选项, 而且**已经漂移**:

    build_sw.py :  CM_OPT = '-O2 -mbranch-cost=1 -fira-loop-pressure'
    mk_cm_hw.py :  opt    = "-Os"                <-- 少了全部三个开关

后果链 (全部是"看起来没事、实际全错"的形态):
  1. `results/NEXT-BURN.md` §3 让人跑 `python tools\\mk_cm_hw.py 4600` -> 烧上去的是
     **-Os** 镜像, 板上实测 324.19 (2026-10-17 的实测日志里
     `Compiler flags : -Os -march=rv32im -mabi=ilp32` 就是证据);
  2. 但 `mk_cm_hw.py` 写进 `cm_hw.build.json` 的 `expect_tick` 是用 **-O2** 仿真日志
     (每迭代 369,506 拍) 算的 -> 清单与镜像**自相矛盾**, 差 25%;
     `fpga_workflow.py hw` 的 0.5% tick 门必然 FAIL;
  3. 于是交付档 tag `deliv150-o2ira` 宣称的 405.9 永远只是**派生值**,
     因为照文档操作永远烧不到那份镜像。

【修法】两处都从这里取, 并且 `mk_cm_hw.py` 额外加一道**漂移即失败**的闸门:
比对"仿真日志里 CoreMark 自报的 Compiler flags"与"本次要用的配方"——
不一致就 BLOCK, 不许猜、不许用旧值。**这比"改对一次"更重要**:
它让同一类漂移以后**自己暴露**而不是静默通过。

【不要在这里加"某平台专属"的开关】
本核的 -O2 + `-mbranch-cost=1` + `-fira-loop-pressure` 是**实测最快**的一档:
  -O2            : ticks 463,364 -> 371,390 (CM/MHz 2.158 -> 2.693)
  + bc=1 + ira   : ticks 371,390 -> 369,506 (-0.507%)
⚠ `-mbranch-cost` **只有 =1 有效**: bc=0 / bc=2 都精确回到基线 371,440 但 .text 变了
   —— "看着改了、其实白改"的陷阱。
⚠ `-O3` 在本核**更慢**: 纯 -O3 溢出 16 KB imem 2,404 B; 混合 -O3/-Os 装得下但慢 0.83%。
⚠ `-O2` 的 .text 余量只剩 ~272 B / 16,384 B => 给 CoreMark 加代码前先量体积。
"""

# ---- 唯一的一份配方 -------------------------------------------------------
# 优化级别与分支代价/寄存器分配开关。
# -mbranch-cost=1 : GCC 默认把分支当"贵"(-mbranch-cost=3), 倾向用算术换分支;
#                    本核有 BTB/PHT, 分支其实便宜 => 1。
# -fira-loop-pressure : 寄存器分配按循环压力优化, 在 bc1 之上再省 318 拍。
CM_OPT = '-O2 -mbranch-cost=1 -fira-loop-pressure'

# ISA / ABI
CM_MARCH = 'rv32im'
CM_MABI = 'ilp32'


def cm_flags_str(opt=None, march=None, abi=None):
    """返回 CoreMark 会打印出来的 `Compiler flags` 字符串 (**逐字符可核对**)。

    这个串就是上板 UART 日志里的 `Compiler flags : ...` 那一行 ——
    所以它既是"编译期配方", 也是"运行期自证", 可以拿来做端到端比对。

    ⚠ 必须与 build_sw.py 里传给 `-D FLAGS_STR="..."` 的内容**完全一致**,
      否则板子自报的 flags 与清单对不上 (比对会假 FAIL)。
    """
    opt = CM_OPT if opt is None else opt
    march = CM_MARCH if march is None else march
    abi = CM_MABI if abi is None else abi
    return '%s -march=%s -mabi=%s' % (opt, march, abi)


def cm_flags_define(opt=None, march=None, abi=None):
    """返回传给 GCC 的 `-D` 宏定义 (含外层双引号)。

    ⚠ 必须作为**一个** argv 元素传出去 (subprocess 列表形式) ——
      shell 里内层双引号会被吃掉 (R15)。
    """
    return 'FLAGS_STR="%s"' % cm_flags_str(opt, march, abi)


if __name__ == '__main__':
    # 自检: 打印出来供人工核对, 同时也是给其它脚本 import 的入口
    print('CM_OPT     = %s' % CM_OPT)
    print('flags_str  = %s' % cm_flags_str())
    print('define     = %s' % cm_flags_define())
