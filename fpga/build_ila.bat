@echo off
set "PROCESSOR_ARCHITECTURE=AMD64"
set "XILINX_VIVADO=D:\software\Learn\Xilinx\Vivado\2018.3"
set "PATH=D:\software\Learn\Xilinx\Vivado\2018.3\bin;D:\software\Learn\Xilinx\Vivado\2018.3\lib\win64.o;%PATH%"
call D:\software\Learn\Xilinx\Vivado\2018.3\bin\vivado.bat -mode batch -nojournal -source "D:\USER\Desktop\FPGA\FPGA\fpga\build_ila.tcl" > "D:\USER\Desktop\FPGA\FPGA\fpga\ila_build.log" 2>&1
echo EXITCODE=%ERRORLEVEL% >> "D:\USER\Desktop\FPGA\FPGA\fpga\ila_build.log"
