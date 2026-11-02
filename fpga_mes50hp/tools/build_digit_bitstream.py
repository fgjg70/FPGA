import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--gcc")
    parser.add_argument("--pds-home", type=Path, default=Path(os.environ.get("PDS_HOME", "E:/PDS")))
    args = parser.parse_args()
    shell = args.pds_home / "bin/pds_shell.exe"
    if not shell.is_file():
        raise FileNotFoundError("Set PDS_HOME or --pds-home to the PDS installation")
    command = [sys.executable, str(ROOT / "prepare_rtl.py"), "--app", "digit"]
    if args.gcc:
        command.extend(["--gcc", args.gcc])
    subprocess.run(command, cwd=ROOT, check=True)
    destination = ROOT / "build/digit"
    inputs = ["generated/riscv_pds.v", "generated/manifest.json", "generated/profile_constraints.fdc", "mes50hp.fdc", "create_project.tcl"]
    inputs.extend(path.relative_to(ROOT).as_posix() for path in sorted((ROOT / "firmware").glob("*.hex")))
    for filename in inputs:
        output = destination / filename
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / filename, output)
    started = time.time()
    for name, arguments in [
        ("create", ["-file", "create_project.tcl", "-work_dir", ".", "-project_name", "riscv_mes50hp_digit"]),
        ("bitstream", ["-project", "riscv_mes50hp_digit.pds", "-run", "gen_bit_stream"]),
    ]:
        log = destination / (name + "_console.log")
        print("PDS", name, "log:", log, flush=True)
        with log.open("w", encoding="utf-8") as output:
            subprocess.run([str(shell), *arguments], cwd=destination, stdout=output,
                           stderr=subprocess.STDOUT, check=True)
        text = log.read_text(encoding="utf-8", errors="replace")
        if re.search(r"(?m)^E:", text):
            raise RuntimeError("PDS reported an error; see " + str(log))
    bitstream = destination / "generate_bitstream/top_mes50hp.sbit"
    if not bitstream.is_file() or bitstream.stat().st_mtime < started:
        raise RuntimeError("PDS did not produce a fresh application bitstream")
    report = {"app": "digit", "hardware_programmed": False,
              "device": "Logos/PGL50H/-6/FBG484", "clock_hz": 50000000,
              "bitstream": bitstream.relative_to(ROOT).as_posix(),
              "bitstream_sha256": hashlib.sha256(bitstream.read_bytes()).hexdigest(),
              "manifest_sha256": hashlib.sha256((destination / "generated/manifest.json").read_bytes()).hexdigest()}
    (destination / "build_summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
