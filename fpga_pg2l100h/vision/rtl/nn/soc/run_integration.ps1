# CPU + NPU 联调复现脚本 (Vivado xsim 2018.3)
# 用法: 在本目录（含全部源）运行
$X = 'D:\software\Learn\Xilinx\Vivado\2018.3\bin'
$order = 'rv32_pkg.sv','nn_pkg.sv','nn_rom_pkg.sv','nn_full.v',
         'alu.sv','bht.sv','branch_unit.sv','btb.sv','control_unit.sv','csr_file.sv','dmem.sv',
         'ex_mem_reg.sv','gemm_accel.sv','hazard_unit.sv','id_ex_reg.sv','imem.sv','imm_gen.sv',
         'load_store_unit.sv','mem_wb_reg.sv','muldiv.sv','pc.sv','ras.sv','regfile.sv',
         'core.sv','mmio_subsys.sv','tb_sw_nn_job.sv'
# 关键: -d NN_EN 必须加, 否则 core.sv 的 nn_* 端口不存在
cmd /c "`"$X\xvlog.bat`" -sv -d NN_EN $($order -join ' ')"
cmd /c "`"$X\xelab.bat`" -L work tb_sw_nn_job --snapshot job_sim --debug typical"
# 跑 (5M 周期上限; 注: 本机 xsim 约 2K 周期/秒, 完整跑完需 1-2 小时)
$R = '<repo>'
cmd /c "`"$X\xsim.bat`" job_sim -R --nolog --testplusarg `"imem=$R/sim/prog/nn_job_demo.hex`" --testplusarg `"dmem=$R/sim/prog/nn_job_demo.dmem.hex`" --testplusarg `"nnwq=$R/sim/prog/yolo320/yolo_wq.hex`" --testplusarg `"max_cycles=5000000`""
