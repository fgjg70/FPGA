@echo off
call "D:\software\Learn\Xilinx\Vivado\2018.3\settings64.bat" >nul 2>&1
cd /d "%~dp0"
vivado -mode batch -nojournal -log build.log -source build.tcl
echo VIVADO_EXIT=%errorlevel%
