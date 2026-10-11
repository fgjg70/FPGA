@echo off
REM ===========================================================================
REM ila_cap_done.bat -- program the ILA image, wait, capture, read the result
REM back into results/ila_done.csv + results/ila_done.capture.json.
REM E-02: paths derive from this script's own location; only the Vivado install
REM is configurable (set VIVADO_SETTINGS=D:\path\to\Vivado\<ver>\settings64.bat).
REM Keep this file PURE ASCII (cmd parses .bat with the OEM code page).
REM ===========================================================================
if "%VIVADO_SETTINGS%"=="" set "VIVADO_SETTINGS=D:\software\Learn\Xilinx\Vivado\2018.3\settings64.bat"
if not exist "%VIVADO_SETTINGS%" (
  echo CAPTURE_ERROR: Vivado settings script not found: "%VIVADO_SETTINGS%"
  echo CAPTURE_HINT: set VIVADO_SETTINGS=^<Vivado^>\settings64.bat
  exit /b 1
)
call "%VIVADO_SETTINGS%" >nul 2>&1
cd /d "%~dp0"
vivado -mode batch -nojournal -log cap_done.log -source "%~dp0ila_cap_done.tcl"
set VIVADO_EXIT=%errorlevel%
echo VIVADO_EXIT=%VIVADO_EXIT%
exit /b %VIVADO_EXIT%
