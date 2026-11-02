import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from build import find_gcc, write_hex


def main():
    work = ROOT / "validation/cpu_mmio"
    firmware = work / "firmware"
    firmware.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    temporary = ROOT / "validation/tmp"
    environment.update(TMP=str(temporary), TEMP=str(temporary), TMPDIR=str(temporary))
    gcc = find_gcc()
    elf = firmware / "test.elf"
    command = [str(gcc), "-march=rv32im", "-mabi=ilp32", "-O2", "-ffreestanding", "-fno-builtin",
               "-nostdlib", "-msmall-data-limit=0", "-mno-relax", "-Wall", "-Wextra", "-Werror"]
    objects = []
    for source in [ROOT / "firmware/start.S", ROOT / "sim/test_cpu_mmio.c"]:
        output = firmware / (source.stem + ".o")
        subprocess.run(command + ["-c", str(source), "-o", str(output)], check=True, env=environment)
        objects.append(str(output))
    linker = gcc.with_name(gcc.name.replace("gcc", "ld"))
    subprocess.run([str(linker), "-m", "elf32lriscv", "--no-relax", "-T", str(ROOT / "firmware/link.ld"), *objects, "-o", str(elf)], check=True, env=environment)
    objcopy = gcc.with_name(gcc.name.replace("gcc", "objcopy"))
    for section, name, fill in [(".text", "vision_imem", "00000013"), (".data", "vision_dmem", "00000000")]:
        binary = firmware / (name + ".bin")
        subprocess.run([str(objcopy), "-O", "binary", "-j", section, str(elf), str(binary)], check=True, env=environment)
        write_hex(binary, firmware / (name + ".hex"), fill)
    for name in ["bht_init.hex", "btb_zero.hex", "regfile_zero.hex"]:
        shutil.copy2(ROOT / "build/j11/firmware" / name, firmware / name)
    tool = Path("C:/Users/chenq/AppData/Local/Temp/codex-fpga-sim/mingw64/bin/iverilog.exe")
    environment["PATH"] = str(tool.parent) + os.pathsep + environment.get("PATH", "")
    output = work / "cpu_mmio.vvp"
    sources = sorted((ROOT / "rtl/cpu").glob("*.v")) + [ROOT / "rtl/vision_mmio_bridge.v", ROOT / "sim/tb_cpu_mmio.v"]
    compile_result = subprocess.run([str(tool), "-B", str(tool.parent.parent / "lib/ivl"), "-g2005", "-s", "tb_cpu_mmio", "-o", str(output), *map(str, sources)], cwd=work, env=environment, capture_output=True)
    (work / "compile.log").write_bytes(compile_result.stdout + compile_result.stderr)
    compile_result.check_returncode()
    completed = subprocess.run([str(tool.parent / "vvp.exe"), str(output)], cwd=work, env=environment, capture_output=True, timeout=60)
    text = (completed.stdout + completed.stderr).decode("utf-8", errors="replace")
    (work / "run.log").write_text(text, encoding="utf-8")
    success = completed.returncode == 0 and "PASS cpu_mmio" in text and "FATAL" not in text
    (work / "summary.json").write_text(json.dumps(dict(success=success, cpu_clock_hz=125000000, peripheral_period_ns=20.74, log=text), indent=2) + "\n", encoding="utf-8")
    print(text)
    if not success:
        raise SystemExit("CPU/MMIO functional regression failed")


if __name__ == "__main__":
    main()
