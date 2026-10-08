@echo off
rem ==========================================================================
rem run.sh - build and run all tests (Linux / WSL / macOS)
rem   1. unit regression : tb_units.sv  (6 RTL modules)
rem   2. system test     : tb_core.sv   (5-stage pipeline, prog/basic.S)
rem Usage: ./sim/run.sh
rem ==========================================================================
set -e
cd "$(dirname "$0")"

command -v iverilog >/dev/null 2>&1 || {
  echo "[ERROR] iverilog not found. Try: sudo apt install iverilog"
  exit 1
}

RTL="../rv32_pkg.sv ../alu.sv ../branch_unit.sv ../control_unit.sv ../imm_gen.sv ../pc.sv ../regfile.sv"

echo
echo "=== [1/2] unit regression (tb_units) ==="
iverilog -g2012 -Wall -o tb_units.vvp $RTL tb_units.sv
vvp tb_units.vvp

echo
echo "=== [2/2] system test (tb_core, 5-stage pipeline) ==="
echo "--- assembling prog/basic.S ---"
python3 ../tools/asm.py prog/basic.S -o prog/basic.hex > prog/basic.lst

RTLPIPE="$RTL ../id_ex_reg.sv ../ex_mem_reg.sv ../mem_wb_reg.sv ../hazard_unit.sv ../load_store_unit.sv ../imem.sv ../dmem.sv ../btb.sv ../muldiv.sv ../csr_file.sv ../core.sv"

iverilog -g2012 -Wall -o tb_core.vvp $RTLPIPE tb_core.sv
vvp tb_core.vvp +imem=prog/basic.hex

echo
echo "=== ALL TESTS PASSED ==="
