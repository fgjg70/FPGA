import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


PROJECT_DIR = Path(__file__).resolve().parent
GENERATED_DIR = PROJECT_DIR / "generated"
RTL_PATH = GENERATED_DIR / "riscv_pds.v"
MANIFEST_PATH = GENERATED_DIR / "manifest.json"
FIRMWARE_PATH = PROJECT_DIR / "firmware"
CONSTRAINT_PATH = GENERATED_DIR / "profile_constraints.fdc"


def profile_constraints(app):
    path = PROJECT_DIR / ("mes50hp_digit.fdc" if app == "digit" else "mes50hp.fdc")
    return {"source": path.name, "source_sha256": sha256(path), "generated_sha256": sha256(CONSTRAINT_PATH)}
def profile_defines(app):
    if app == "digit":
        return ["SYNTHESIS", "GEMM_EN", "DIGIT_APP",
                'IMEM_INIT_FILE="firmware/digit_imem.hex"',
                'DMEM_INIT_FILE="firmware/digit_dmem.hex"']
    return ["SYNTHESIS", 'IMEM_INIT_FILE="firmware/boot.hex"',
            'DMEM_INIT_FILE="firmware/dmem_zero.hex"']


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_paths():
    filenames = (PROJECT_DIR / "sources.f").read_text(encoding="utf-8").splitlines()
    paths = [PROJECT_DIR / filename.strip() for filename in filenames if filename.strip()]
    for path in paths:
        if not path.is_file():
            raise FileNotFoundError(f"Missing source: {path}")
    return paths


def build_firmware(app, gcc=None):
    FIRMWARE_PATH.mkdir(exist_ok=True)
    if app == "digit":
        command = [sys.executable, str(PROJECT_DIR / "tools/build_digit.py")]
        if gcc:
            command.extend(["--gcc", gcc])
        subprocess.run(command, cwd=PROJECT_DIR, check=True)
    else:
        with tempfile.TemporaryDirectory(prefix="assemble-", dir=FIRMWARE_PATH) as temporary_dir:
            words_path = Path(temporary_dir) / "boot.hex"
            listing = subprocess.check_output(
                [sys.executable, str(PROJECT_DIR / "tools" / "asm.py"),
                 str(FIRMWARE_PATH / "boot.S"), "-o", str(words_path)],
                cwd=PROJECT_DIR,
            )
            words = words_path.read_text(encoding="utf-8").splitlines()
            if len(words) > 4096:
                raise ValueError("Boot image exceeds the 16 KiB instruction memory.")
            (FIRMWARE_PATH / "boot.hex").write_text(
                "\n".join(words + ["00000013"] * (4096 - len(words))) + "\n", encoding="utf-8"
            )
        (PROJECT_DIR / "validation").mkdir(exist_ok=True)
        (PROJECT_DIR / "validation" / "boot.listing.log").write_bytes(listing)
    for filename, word, count in [
        ("dmem_zero.hex", "00000000", 4096),
        ("bht_init.hex", "1", 8192),
        ("btb_zero.hex", "0", 512),
        ("regfile_zero.hex", "00000000", 32),
    ]:
        (FIRMWARE_PATH / filename).write_text((word + "\n") * count, encoding="utf-8")


def firmware_hashes(app):
    if app == "digit":
        paths = [PROJECT_DIR / path for path in ["firmware/digit/start.S", "firmware/digit/main.c", "firmware/digit/platform.c", "firmware/digit/platform.h",
                 "firmware/digit/link.ld", "model/digit_model.h", "tools/build_digit.py",
                 "firmware/digit_imem.hex", "firmware/digit_dmem.hex"]]
    else:
        paths = [FIRMWARE_PATH / "boot.S", PROJECT_DIR / "tools" / "asm.py", FIRMWARE_PATH / "boot.hex"]
    paths.extend(FIRMWARE_PATH / name for name in ["dmem_zero.hex", "bht_init.hex", "btb_zero.hex", "regfile_zero.hex"])
    return {path.relative_to(PROJECT_DIR).as_posix(): sha256(path) for path in paths}


def main():
    parser = argparse.ArgumentParser(description="Generate PDS-compatible Verilog from src/.")
    parser.add_argument("--sv2v", default=os.environ.get("SV2V"))
    parser.add_argument("--check", action="store_true", help="Check generated RTL freshness.")
    parser.add_argument("--app", choices=["boot", "digit"])
    parser.add_argument("--gcc", help="RISC-V GCC executable for the digit application.")
    args = parser.parse_args()
    paths = source_paths()
    source_hashes = {path.relative_to(PROJECT_DIR).as_posix(): sha256(path) for path in paths}

    if args.check:
        manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
        app = args.app or manifest.get("app", "boot")
        defines = profile_defines(app)
        if (manifest["sources"] != source_hashes
                or manifest["firmware"] != firmware_hashes(app)
                or manifest["defines"] != defines
                or manifest.get("constraints") != profile_constraints(app)
                or manifest["rtl_sha256"] != sha256(RTL_PATH)):
            raise RuntimeError(f"Generated RTL is stale. Run prepare_rtl.py --app {app}.")
        print(f"PASS: {app} RTL matches all {len(paths)} source files and firmware.")
        return

    converter = args.sv2v or PROJECT_DIR / "tools" / "sv2v" / "sv2v.exe"
    converter_path = shutil.which(str(converter))
    if not converter_path:
        raise FileNotFoundError("sv2v not found. Set SV2V or run setup_tools.ps1.")
    version = subprocess.check_output([converter_path, "--numeric-version"], text=True).strip()
    app = args.app or "boot"
    defines = profile_defines(app)
    build_firmware(app, args.gcc)
    GENERATED_DIR.mkdir(exist_ok=True)
    constraints = PROJECT_DIR / ("mes50hp_digit.fdc" if app == "digit" else "mes50hp.fdc")
    CONSTRAINT_PATH.write_bytes(constraints.read_bytes())
    with tempfile.TemporaryDirectory(prefix="convert-", dir=GENERATED_DIR) as temporary_dir:
        temporary_rtl = Path(temporary_dir) / "riscv_pds.v"
        subprocess.run(
            [converter_path, *[f"-D{define}" for define in defines],
             f"--write={temporary_rtl}", *map(str, paths)],
            cwd=PROJECT_DIR,
            check=True,
        )
        converted_text = temporary_rtl.read_text(encoding="utf-8")
        temporary_rtl.write_text("`timescale 1ns/1ps\n" + converted_text, encoding="utf-8")
        temporary_rtl.replace(RTL_PATH)
    manifest = {
        "app": app,
        "converter": f"sv2v {version}",
        "converter_sha256": sha256(Path(converter_path)),
        "defines": defines,
        "sources": source_hashes,
        "firmware": firmware_hashes(app),
        "constraints": profile_constraints(app),
        "rtl_sha256": sha256(RTL_PATH),
    }
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Generated {RTL_PATH.relative_to(PROJECT_DIR)} from {len(paths)} sources using sv2v {version}.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
