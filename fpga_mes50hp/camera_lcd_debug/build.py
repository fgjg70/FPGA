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

from generate_pins import generate


ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description="Build MES50HP OV7670 FIFO + AN430 debug project")
    parser.add_argument("--pds-home", type=Path, default=Path(os.environ.get("PDS_HOME", "E:/PDS")))
    args = parser.parse_args()
    shell = args.pds_home / "bin/pds_shell.exe"
    if not shell.is_file():
        parser.error("Set PDS_HOME or --pds-home to the PDS installation directory")
    generate()
    destination = ROOT / "build"
    destination.mkdir(exist_ok=True)
    inputs = sorted((ROOT / "rtl").glob("*.v")) + [ROOT / "create_project.tcl", ROOT / "mes50hp_camera_lcd.fdc"]
    for source in inputs:
        target = destination / source.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    tracked = inputs + [ROOT / "generate_pins.py", ROOT / "build.py", ROOT / "wiring.csv"]
    started = time.time()
    report = dict(success=False, hardware_programmed=False, device="Logos/PGL50H/-6/FBG484",
                  top_module="top_camera_lcd_debug", system_clock_hz=27000000,
                  lcd_clock_hz=9000000, lcd_active=[480, 272], lcd_total=[525, 286],
                  camera_format="QVGA RGB565 FIFO", stored_image=[160, 120], uart_baud=115200,
                  input_sha256={path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                                for path in tracked})
    summary = destination / "build_summary.json"
    summary.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    steps = [
        ("create", ["-file", "create_project.tcl", "-work_dir", ".", "-project_name", "mes50hp_camera_lcd"]),
        ("bitstream", ["-project", str(destination / "mes50hp_camera_lcd.pds"), "-run", "gen_bit_stream"]),
    ]
    for name, arguments in steps:
        log = destination / (name + "_console.log")
        print(f"PDS {name}: {log}", flush=True)
        with log.open("w", encoding="utf-8") as output:
            result = subprocess.run([str(shell), *arguments], cwd=destination, stdout=output, stderr=subprocess.STDOUT)
        text = log.read_text(encoding="utf-8", errors="replace")
        if result.returncode or re.search(r"(?m)^E:", text):
            raise RuntimeError(f"PDS {name} failed; see {log}")
    bitstream = destination / "generate_bitstream/top_camera_lcd_debug.sbit"
    if not bitstream.is_file() or bitstream.stat().st_mtime < started:
        raise RuntimeError("PDS did not produce a fresh bitstream")
    timing = destination / "place_route/top_camera_lcd_debug_timing_summary_after_hold_fix.txt"
    if not timing.is_file() or "Design Summary : All Constraints Met." not in timing.read_text(errors="replace"):
        raise RuntimeError(f"Timing did not pass; inspect {timing}")
    report.update(success=True, timing_constraints_met=True,
                  completed_utc=datetime.now(timezone.utc).isoformat(),
                  elapsed_seconds=round(time.time() - started, 2),
                  project="build/mes50hp_camera_lcd.pds",
                  bitstream=bitstream.relative_to(ROOT).as_posix(),
                  bitstream_bytes=bitstream.stat().st_size,
                  bitstream_sha256=hashlib.sha256(bitstream.read_bytes()).hexdigest())
    summary.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"PASS: {bitstream} ({report['bitstream_bytes']} bytes), timing constraints met", flush=True)


if __name__ == "__main__":
    main()
