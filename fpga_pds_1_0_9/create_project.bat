@echo off
setlocal
if not defined PDS_HOME set "PDS_HOME=E:\PDS"
set "PDS_SHELL=%PDS_HOME%\bin\pds_shell.exe"
if not exist "%PDS_SHELL%" (
    echo PDS shell not found: "%PDS_SHELL%"
    echo Set PDS_HOME to the PDS installation directory.
    exit /b 1
)
pushd "%~dp0"
if errorlevel 1 exit /b 1
python prepare_rtl.py
if errorlevel 1 (
    popd
    exit /b 1
)
"%PDS_SHELL%" -file create_project.tcl -work_dir . -project_name riscv_pgl22g
set "PDS_RESULT=%errorlevel%"
popd
exit /b %PDS_RESULT%
