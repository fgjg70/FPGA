@echo off
REM ===========================================================================
REM build.bat -- scoring build (non-project mode), run from anywhere.
REM E-02: no hardcoded PROJECT path any more. build.tcl derives the repository
REM root from its own location, so this wrapper only needs the Vivado install.
REM Override the Vivado install (other machine / other version) with:
REM     set VIVADO_SETTINGS=D:\path\to\Vivado\<ver>\settings64.bat
REM Keep this file PURE ASCII (cmd parses .bat with the OEM code page).
REM ===========================================================================
if "%VIVADO_SETTINGS%"=="" set "VIVADO_SETTINGS=D:\software\Learn\Xilinx\Vivado\2018.3\settings64.bat"
if not exist "%VIVADO_SETTINGS%" (
  echo BUILD_ERROR: Vivado settings script not found: "%VIVADO_SETTINGS%"
  echo BUILD_HINT: set VIVADO_SETTINGS=^<Vivado^>\settings64.bat
  exit /b 1
)
call "%VIVADO_SETTINGS%" >nul 2>&1
cd /d "%~dp0"
REM Absolute -source so [info script] is well defined (hint: Vivado must be the
REM only instance running -- two overlapping instances break IP generation).
vivado -mode batch -nojournal -log build.log -source "%~dp0build.tcl"
set VIVADO_EXIT=%errorlevel%
echo VIVADO_EXIT=%VIVADO_EXIT%
exit /b %VIVADO_EXIT%
