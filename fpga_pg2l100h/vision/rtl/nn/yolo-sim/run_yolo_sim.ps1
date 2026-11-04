# ============================================================================
# run_yolo_sim.ps1 -- COCO-80 YOLO-Fastest v1.1 NPU simulation (one command)
#
# Model : YOLO-Fastest v1.1 (darknet), COCO 80 classes, 131 layers
#         frozen spec : results/ai-accel/MODEL-FREEZE.md
#         op sequence : 112 ops (nn_rom_pkg::NN_ROM)
# DUT   : nn_full.v  (7 modules, pure Verilog converted from SV by sv2v)
# TB    : tb_nn_seq.sv (runs the real YOLO ROM 112 ops + band loop/prefetch)
# Pass  : "NN_SEQ_TB: PASS (legacy starts=112 cycles=336 | band ops=112 bands=4242 ...)"
# Time  : about 10 seconds (72k cycles)
#
# Requires: Vivado 2018.3 xsim (xvlog / xelab / xsim)
# Usage   : powershell -ExecutionPolicy Bypass -File run_yolo_sim.ps1
#
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads .ps1 as ANSI
#       when there is no BOM, so non-ASCII comments break the parser (R2 rule).
# ============================================================================
$ErrorActionPreference = 'Stop'
$X = 'D:\software\Learn\Xilinx\Vivado\2018.3\bin'
if (-not (Test-Path "$X\xvlog.bat")) { Write-Host "Vivado xsim not found: $X"; exit 1 }

# Remove xsim run artifacts so the directory stays clean (see .gitignore)
function Invoke-Cleanup {
    Get-ChildItem $PSScriptRoot -File -EA SilentlyContinue |
        Where-Object { $_.Name -match '\.(log|jou|pb|wdb)$' -or $_.Name -match 'backup\.' } |
        Remove-Item -Force -EA SilentlyContinue
    foreach ($d in 'xsim.dir','Xil','.Xil') {
        Remove-Item (Join-Path $PSScriptRoot $d) -Recurse -Force -EA SilentlyContinue
    }
}

Invoke-Cleanup
Push-Location $PSScriptRoot
try {
    Write-Host "== [1/3] compile (packages -> RTL -> TB) =="
    $srcs = @('rv32_pkg.sv','nn_pkg.sv','nn_rom_pkg.sv','nn_full.v','tb_nn_seq.sv')
    cmd /c "`"$X\xvlog.bat`" -sv $($srcs -join ' ')"
    if ($LASTEXITCODE -ne 0) { Write-Host "compile FAILED"; exit 1 }

    Write-Host "== [2/3] elaborate =="
    cmd /c "`"$X\xelab.bat`" -L work tb_nn_seq --snapshot yolo_sim --debug typical"
    if ($LASTEXITCODE -ne 0) { Write-Host "elaborate FAILED"; exit 1 }

    Write-Host "== [3/3] run simulation =="
    $out = cmd /c "`"$X\xsim.bat`" yolo_sim -R --nolog 2>&1"
    $out | ForEach-Object { Write-Host $_ }

    $pass = ($out | Select-String -Pattern 'NN_SEQ_TB: PASS' -Quiet)
    if ($pass) { Write-Host "" ; Write-Host ">>> YOLO simulation PASS"; exit 0 }
    else       { Write-Host "" ; Write-Host ">>> YOLO simulation FAIL"; exit 1 }
}
finally {
    Invoke-Cleanup
    Pop-Location
}
