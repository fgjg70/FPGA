@echo off
rem ==========================================================================
rem run.bat - build and run all tests (Windows)
rem   1. unit regression : tb_units.sv  (6 RTL modules)
rem   2. system test     : tb_core.sv   (5-stage pipeline, prog/basic.S)
rem Usage: sim\run.bat   (works from any directory)
rem Note: keep this file ASCII-only (cmd parses .bat in OEM codepage)
rem ==========================================================================
setlocal
cd /d "%~dp0"

rem iverilog lookup order: 1) system PATH  2) local tools dir (riscv-tools)
if exist "%LOCALAPPDATA%\riscv-tools\mingw64\bin\iverilog.exe" (
  set "PATH=%LOCALAPPDATA%\riscv-tools\mingw64\bin;%PATH%"
)
where iverilog >nul 2>nul
if errorlevel 1 (
  echo [ERROR] iverilog not found. Install one of:
  echo         1. MSYS2: pacman -S mingw-w64-x86_64-iverilog
  echo         2. WSL:   sudo apt install iverilog
  echo         3. oss-cad-suite from YosysHQ GitHub releases
  exit /b 1
)

set "RTL=..\rv32_pkg.sv ..\alu.sv ..\branch_unit.sv ..\control_unit.sv ..\imm_gen.sv ..\pc.sv ..\regfile.sv"

echo.
echo === [1/2] unit regression test (tb_units) ===
iverilog -g2012 -Wall -o tb_units.vvp %RTL% tb_units.sv
if errorlevel 1 ( echo [ERROR] unit compile failed & exit /b 1 )
vvp tb_units.vvp
if errorlevel 1 ( echo [ERROR] unit test FAILED & exit /b 1 )

echo.
echo === [2/2] system test (tb_core, 5-stage pipeline) ===
echo --- assembling prog/basic.S ---
where py >nul 2>nul && ( py ..\tools\asm.py prog\basic.S -o prog\basic.hex > prog\basic.lst )
if not exist prog\basic.hex (
  python ..\tools\asm.py prog\basic.S -o prog\basic.hex > prog\basic.lst
)
if not exist prog\basic.hex ( echo [ERROR] assembly failed & exit /b 1 )

set "RTLPIPE=%RTL% ..\..\id_ex_reg.sv ..\ex_mem_reg.sv ..\mem_wb_reg.sv ..\hazard_unit.sv ..\load_store_unit.sv ..\imem.sv ..\dmem.sv ..\core.sv"

iverilog -g2012 -Wall -o tb_core.vvp %RTLPIPE% tb_core.sv
if errorlevel 1 ( echo [ERROR] core compile failed & exit /b 1 )
vvp tb_core.vvp +imem=prog/basic.hex
if errorlevel 1 ( echo [ERROR] core test FAILED & exit /b 1 )

echo.
echo === ALL TESTS PASSED ===
exit /b 0
