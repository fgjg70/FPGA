# ============================================================================
# run_yolo_sim.ps1 —— COCO-80 YOLO-Fastest v1.1 的 NPU 仿真（一键）
#
# 被测模型: YOLO-Fastest v1.1 (darknet), COCO 80 类, 131 层
#           冻结记录: results/ai-accel/MODEL-FREEZE.md
#           层序列:   112 op (nn_rom_pkg::NN_ROM)
# DUT:      nn_full.v (7 个模块的纯 Verilog 版, 由 SV 经 sv2v 转换)
# TB:       tb_nn_seq.sv (跑真实 YOLO ROM 的 112 个 op + band 循环/预取)
# 判据:     "NN_SEQ_TB: PASS (legacy starts=112 cycles=336 | band ops=112 bands=4242 ...)"
# 用时:     约 40 秒 (7.2 万拍)
#
# 依赖: Vivado 2018.3 xsim (xvlog/xelab/xsim)
# 用法: powershell -ExecutionPolicy Bypass -File run_yolo_sim.ps1
# ============================================================================
$ErrorActionPreference = 'Stop'
$X = 'D:\software\Learn\Xilinx\Vivado\2018.3\bin'
if (-not (Test-Path "$X\xvlog.bat")) { Write-Host "找不到 Vivado xsim: $X"; exit 1 }

Push-Location $PSScriptRoot
try {
    Write-Host "== [1/3] 编译 (包 -> RTL -> TB) =="
    $srcs = @('rv32_pkg.sv','nn_pkg.sv','nn_rom_pkg.sv','nn_full.v','tb_nn_seq.sv')
    cmd /c "`"$X\xvlog.bat`" -sv $($srcs -join ' ')"
    if ($LASTEXITCODE -ne 0) { Write-Host "编译失败"; exit 1 }

    Write-Host "== [2/3] elaborate =="
    cmd /c "`"$X\xelab.bat`" -L work tb_nn_seq --snapshot yolo_sim --debug typical"
    if ($LASTEXITCODE -ne 0) { Write-Host "elaborate 失败"; exit 1 }

    Write-Host "== [3/3] 运行仿真 =="
    $out = cmd /c "`"$X\xsim.bat`" yolo_sim -R --nolog 2>&1"
    $out | ForEach-Object { Write-Host $_ }

    $pass = ($out | Select-String -Pattern 'NN_SEQ_TB: PASS' -Quiet)
    if ($pass) { Write-Host "`n>>> YOLO 仿真 PASS" ; exit 0 }
    else       { Write-Host "`n>>> YOLO 仿真 FAIL" ; exit 1 }
}
finally { Pop-Location }
