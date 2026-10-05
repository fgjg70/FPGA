@echo off
REM Mirror the already-proven programming flow (settings64.bat + vivado from PATH + -log)
call "D:\software\Learn\Xilinx\Vivado\2018.3\settings64.bat" >nul 2>&1
cd /d "D:\USER\Desktop\FPGA\FPGA\fpga"
vivado -mode batch -nojournal -log cap_mark.log -source "D:\USER\Desktop\FPGA\FPGA\fpga\ila_cap_mark.tcl"
echo VIVADO_EXIT=%errorlevel%
