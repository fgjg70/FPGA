import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time


ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description="Build the independent MES50HP IO debug bitstream")
    parser.add_argument("--pds-home", type=Path, default=Path(os.environ.get("PDS_HOME", "E:/PDS")))
    args = parser.parse_args()
    shell = args.pds_home / "bin/pds_shell.exe"
    if not shell.is_file():
        parser.error("Set PDS_HOME or --pds-home to the PDS installation directory")
    destination = ROOT / "build"
    destination.mkdir(exist_ok=True)
    summary_path = destination / "build_summary.json"
    inputs = sorted((ROOT / "rtl").glob("*.v")) + [ROOT / "create_project.tcl", ROOT / "mes50hp_io_debug.fdc"]
    for source in inputs:
        target = destination / source.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    started = time.time()
    report = {
        "success": False,
        "hardware_programmed": False,
        "device": "Logos/PGL50H/-6/FBG484",
        "top_module": "top_io_debug",
        "clock_hz": 50000000,
        "pixel_clock_hz": 27000000,
        "video_mode": "720x576p50",
        "uart_baud": 115200,
        "keys": ["KEY2", "KEY3", "KEY4", "KEY5", "KEY6", "KEY7"],
        "input_sha256": {path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                         for path in inputs},
    }
    summary_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    steps = [
        ("create", ["-file", "create_project.tcl", "-work_dir", ".",
                    "-project_name", "mes50hp_io_debug"]),
        ("bitstream", ["-project", str(destination / "mes50hp_io_debug.pds"), "-run", "gen_bit_stream"]),
    ]
    for name, arguments in steps:
        log = destination / (name + "_console.log")
        print(f"PDS {name}: {log}", flush=True)
        with log.open("w", encoding="utf-8") as output:
            result = subprocess.run([str(shell), *arguments], cwd=destination, stdout=output,
                                    stderr=subprocess.STDOUT)
        text = log.read_text(encoding="utf-8", errors="replace")
        if result.returncode or re.search(r"(?m)^E:", text):
            raise RuntimeError(f"PDS {name} failed; see {log}")
    bitstream = destination / "generate_bitstream/top_io_debug.sbit"
    if not bitstream.is_file() or bitstream.stat().st_mtime < started:
        raise RuntimeError("PDS did not produce a fresh top_io_debug.sbit")
    report.update({
        "success": True,
        "completed_utc": datetime.now(timezone.utc).isoformat(),
        "elapsed_seconds": round(time.time() - started, 2),
        "project": "build/mes50hp_io_debug.pds",
        "bitstream": bitstream.relative_to(ROOT).as_posix(),
        "bitstream_bytes": bitstream.stat().st_size,
        "bitstream_sha256": hashlib.sha256(bitstream.read_bytes()).hexdigest(),
    })
    summary_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
