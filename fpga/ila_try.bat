@echo off
call "D:\software\Learn\Xilinx\Vivado\2018.3\settings64.bat" >nul 2>&1
cd /d "D:\USER\Desktop\FPGA\FPGA\fpga"
vivado -mode batch -nojournal -log ila_try.log -source "D:\USER\Desktop\FPGA\FPGA\fpga\ila_try.tcl"
echo VIVADO_EXIT=%errorlevel%
