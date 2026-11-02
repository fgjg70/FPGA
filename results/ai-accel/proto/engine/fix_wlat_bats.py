# -*- coding: utf-8 -*-
"""修 bat 生成: vlog 多文件行需要每个续行 '^' (原来只有两行带 ^, 导致只编译到 stub)。"""
import io
import os

HERE = os.path.dirname(os.path.abspath(__file__))


def bat(name, files, work):
    hdr = [
        "@echo off",
        'set "LM_LICENSE_FILE=D:\\software\\tools\\Modelsim\\win64\\LICENSE.TXT"',
        'set "PATH=D:\\software\\tools\\Modelsim\\win64;C:\\Windows\\System32;C:\\Windows"',
        'set "MODELSIM=D:\\software\\tools\\Modelsim\\win64"',
        'set "WORKDIR=%~dp0' + work + '"',
        'set "REPO=%~dp0..\\..\\..\\.."',
        'set "VECDIR=%~1"',
        'if "%VECDIR%"=="" set "VECDIR=%~dp0vec"',
        'if not exist "%WORKDIR%" mkdir "%WORKDIR%"',
        'cd /d "%WORKDIR%"',
        '"%MODELSIM%\\vlib.exe" work >nul 2>&1',
    ]
    allf = ['"%REPO%\\rv32_pkg.sv"', '"%REPO%\\nn_pkg.sv"'] + files
    vlog = '"%MODELSIM%\\vlog.exe" -sv -work work'
    for i, f in enumerate(allf):
        cont = " ^" if i < len(allf) - 1 else ""
        vlog += "\r\n  " + f + cont
    lines = hdr + [vlog, "if errorlevel 1 exit /b 1",
                   '"%MODELSIM%\\vsim.exe" -c -do "run -all; quit -f" work.tb_nn_engine +vec="%VECDIR%" %2 %3',
                   "exit /b %errorlevel%"]
    io.open(os.path.join(HERE, name), "w", encoding="ascii").write("\r\n".join(lines) + "\r\n")


bat("run_v3w.bat", ['"%~dp0nn_mem_v07_stub.sv"', '"%~dp0nn_conv_engine_v3.sv"',
                    '"%~dp0tb_nn_engine_v3w.sv"'], "work_v3w")
bat("run_v3rw.bat", ['"%~dp0..\\mem\\nn_mem_pipe.sv"', '"%~dp0nn_conv_engine_v3.sv"',
                     '"%~dp0tb_nn_engine_v3rw.sv"'], "work_v3rw")
print("run bats regenerated with correct continuations")
