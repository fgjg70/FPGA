import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ["firmware/digit/start.S", "firmware/digit/main.c", "firmware/digit/platform.c", "firmware/digit/platform.h", "firmware/digit/link.ld",
           "model/digit_model.h", "tools/build_digit.py"]


def find_gcc(specified=None):
    candidates = [specified, os.environ.get("RISCV_GCC"), shutil.which("riscv-none-elf-gcc"),
                  shutil.which("riscv32-unknown-elf-gcc"), shutil.which("riscv64-unknown-elf-gcc")]
    cache = Path.home() / "AppData/Local/CodexFPGA/tools"
    candidates.extend(str(path) for path in cache.glob("*/bin/riscv-none-elf-gcc.exe"))
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return Path(candidate).resolve()
    raise FileNotFoundError("RISC-V GCC not found. Pass --gcc or set RISCV_GCC to the compiler executable.")


def write_hex(binary, output, fill):
    contents = binary.read_bytes()
    if len(contents) > 16384:
        raise ValueError(f"{binary.name} exceeds 16 KiB")
    contents += bytes((-len(contents)) % 4)
    words = [f"{int.from_bytes(contents[offset:offset + 4], 'little'):08x}" for offset in range(0, len(contents), 4)]
    output.write_text("\n".join(words + [fill] * (4096 - len(words))) + "\n", encoding="ascii")
    return len(contents)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--gcc")
    args = parser.parse_args()
    gcc = find_gcc(args.gcc)
    suffix = gcc.suffix
    prefix = gcc.name.removesuffix("gcc" + suffix)
    objcopy = gcc.with_name(prefix + "objcopy" + suffix)
    linker = gcc.with_name(prefix + "ld" + suffix)
    build = ROOT / "firmware/digit/build"
    build.mkdir(parents=True, exist_ok=True)
    common = [str(gcc), "-march=rv32im", "-mabi=ilp32", "-O2", "-ffreestanding", "-fno-builtin",
              "-fno-strict-aliasing", "-fno-stack-protector", "-fno-pic", "-msmall-data-limit=0",
              "-mno-relax", "-Wall", "-Wextra", "-Werror", "-I", str(ROOT / "model")]
    objects = []
    for source in ["firmware/digit/start.S", "firmware/digit/main.c", "firmware/digit/platform.c"]:
        target = build / (Path(source).stem + ".o")
        subprocess.run(common + ["-c", str(ROOT / source), "-o", str(target)], check=True, cwd=ROOT)
        objects.append(str(target))
    elf = build / "digit.elf"
    subprocess.run([str(linker), "-m", "elf32lriscv", "--no-relax", "-T", str(ROOT / "firmware/digit/link.ld"),
                    "-Map", str(build / "digit.map"), *objects, "-o", str(elf)], check=True, cwd=ROOT)
    sizes = {}
    for section, filename, fill in [(".text", "digit_imem", "00000013"), (".data", "digit_dmem", "00000000")]:
        binary = build / (filename + ".bin")
        subprocess.run([str(objcopy), "-O", "binary", "-j", section, str(elf), str(binary)], check=True, cwd=ROOT)
        sizes[filename + "_bytes"] = write_hex(binary, ROOT / "firmware" / (filename + ".hex"), fill)
    hashes = {source: hashlib.sha256((ROOT / source).read_bytes()).hexdigest() for source in SOURCES}
    report = {"compiler": subprocess.check_output([str(gcc), "--version"], text=True).splitlines()[0],
              "isa": "rv32im", "clock_hz": 50000000, "sources": hashes, **sizes}
    (build / "build.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    samples = json.loads((ROOT / "model/samples.json").read_text(encoding="utf-8"))
    (build / "digit_logits.hex").write_text(
        "\n".join(f"{value & 0xffffffff:08x}" for row in samples["logits"] for value in row) + "\n", encoding="ascii")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
