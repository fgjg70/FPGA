# CPU + NPU 联调 —— 编译与 elaborate 证据 (2026-11-04)

## 结论
CPU（core.sv，SystemVerilog，~110KB）+ **转换后的 Verilog NPU**（nn_full.v，7 模块）
+ mmio_subsys + tb_sw_nn_job **全部编译通过（rc=0）并 elaborate 通过（rc=0）**。

## 关键命令（可复现）
`powershell
# 1) 按依赖顺序编译（包 → RTL → TB），**必须带 -d NN_EN**
xvlog -sv -d NN_EN rv32_pkg.sv nn_pkg.sv nn_rom_pkg.sv nn_full.v 
    alu.sv bht.sv branch_unit.sv btb.sv control_unit.sv csr_file.sv dmem.sv 
    ex_mem_reg.sv gemm_accel.sv hazard_unit.sv id_ex_reg.sv imem.sv imm_gen.sv 
    load_store_unit.sv mem_wb_reg.sv muldiv.sv pc.sv ras.sv regfile.sv 
    core.sv mmio_subsys.sv tb_sw_nn_job.sv
# rc=0，26 个源文件全部分析通过

# 2) elaborate
xelab -L work tb_sw_nn_job --snapshot job_sim --debug typical
# rc=0
`

## 联调必需的 2 处修正（联调过程中发现的真问题）
| # | 问题 | 修正 |
|---|---|---|
| 1 | core.sv 的 
n_* 端口被 ` ifdef NN_EN ` 包住（L84），不定义则端口不存在 → cannot find port 'nn_addr' | 编译时加 **-d NN_EN** |
| 2 | core.sv:198/878 的 md_op_r/md_op_eff 是 logic [4:0]/wire [4:0]，而 muldiv.op 是 **lu_op_e 枚举**；xsim 比综合器严格 | 改为 lu_op_e md_op_r; / wire alu_op_e md_op_eff = ...;（类型等价，综合行为不变） |

## 固件与镜像（本机可重建）
- RISC-V GCC 实际路径：D:\software\tools\riscv-none-elf\xpack-riscv-none-elf-gcc-15.2.0-1\bin
  （uild_sw.py 的 DEFAULT_GCC_DIR 已指向此路径）
- python tools/build_sw.py --all --with-hw --gcc-dir <上述> → **17 个回归镜像 + 47 个 .hex 全部重建成功**
- 联调用：sim/prog/nn_job_demo.hex（CPU-NPU 解耦 job 模式 demo，期望 NPU 跑 1,191,020 周期）
  + sim/prog/nn_job_demo.dmem.hex
  + sim/prog/yolo320/yolo_wq.hex（W 81,920 行 + Q 12,288 行，与 nn_rom_pkg 的 112-op 计划配套）

## 未完成：xsim 吞吐瓶颈
- 	b_sw_nn_job 的仿真上限 5M 周期，实际跑到 **40 分钟仅推进 ~5M 周期的一半**（约 **2K 周期/秒**，
  比实时慢约 4000×）。
- 原因：CPU 是 110KB 的 SV RTL + NPU 含 320KB ROM，xsim 在 --debug typical 下逐事件解释执行。
- **可加速的方向**（未做）：
  1. xelab 去掉 --debug typical（或改 --debug off 再 -O3）—— 预计 3-5×
  2. 把 W/Q 从 $fopen/ 加载改成 $readmemh（少一次文本解析）
  3. 用更小的固件先验证握手（如 1-op job），再跑完整 112-op
  4. 改用 Verilator（本机未装）
