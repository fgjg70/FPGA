# -*- coding: utf-8 -*-
"""生成 W_RD_LAT=2 的两套 TB / run 脚本:
   - tb_nn_engine_v3w.sv   : stub(W_LAT=2) + engine(W_RD_LAT=2)   (理想时延模型)
   - tb_nn_engine_v3rw.sv  : 真 nn_mem_pipe(proto/mem) + engine(W_RD_LAT=2) (联合)
"""
import io
import os

HERE = os.path.dirname(os.path.abspath(__file__))

# --- TB with stub ---
s = io.open(os.path.join(HERE, "tb_nn_engine_v3.sv"), encoding="utf-8").read()
s = s.replace("nn_mem_v07_stub #(.A_BYTES(96*1024), .B_BYTES(32*1024)) u_mem (",
              "nn_mem_v07_stub #(.A_BYTES(96*1024), .B_BYTES(32*1024), .W_LAT(2)) u_mem (")
s = s.replace("nn_conv_engine #(.OC_LANES(16), .PX_LANES(8)) u_eng (",
              "nn_conv_engine #(.OC_LANES(16), .PX_LANES(8), .W_RD_LAT(2)) u_eng (")
assert ".W_LAT(2)" in s and ".W_RD_LAT(2)" in s
io.open(os.path.join(HERE, "tb_nn_engine_v3w.sv"), "w", encoding="utf-8").write(s)

# --- TB with real nn_mem_pipe ---
r = io.open(os.path.join(HERE, "tb_nn_engine_v3r.sv"), encoding="utf-8").read()
r = r.replace("nn_mem #(.A_BYTES(96*1024), .B_BYTES(32*1024)) u_mem (",
              "nn_mem_pipe #(.A_BYTES(96*1024), .B_BYTES(32*1024)) u_mem (")
r = r.replace("nn_conv_engine #(.OC_LANES(16), .PX_LANES(8)) u_eng (",
              "nn_conv_engine #(.OC_LANES(16), .PX_LANES(8), .W_RD_LAT(2)) u_eng (")
assert "nn_mem_pipe" in r and ".W_RD_LAT(2)" in r
io.open(os.path.join(HERE, "tb_nn_engine_v3rw.sv"), "w", encoding="utf-8").write(r)

# --- run scripts ---
def bat(name, vlog_files, work):
    lines = [
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
        '"%MODELSIM%\\vlog.exe" -sv -work work ^',
        '  "%REPO%\\rv32_pkg.sv" ^',
        '  "%REPO%\\nn_pkg.sv" ^',
    ] + ["  " + f for f in vlog_files] + [
        'if errorlevel 1 exit /b 1',
        '"%MODELSIM%\\vsim.exe" -c -do "run -all; quit -f" work.tb_nn_engine +vec="%VECDIR%" %2 %3',
        "exit /b %errorlevel%",
    ]
    io.open(os.path.join(HERE, name), "w", encoding="ascii").write("\r\n".join(lines) + "\r\n")

bat("run_v3w.bat", ['"%~dp0nn_mem_v07_stub.sv"', '"%~dp0nn_conv_engine_v3.sv"',
                    '"%~dp0tb_nn_engine_v3w.sv"'], "work_v3w")
bat("run_v3rw.bat", ['"%~dp0..\\mem\\nn_mem_pipe.sv"', '"%~dp0nn_conv_engine_v3.sv"',
                     '"%~dp0tb_nn_engine_v3rw.sv"'], "work_v3rw")
print("TB variants + run scripts written")
