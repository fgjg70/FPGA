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
from project_file import prepare_project


ROOT = Path(__file__).resolve().parent
COMMON = ROOT.parents[1] / "fpga_mes50hp/camera_lcd_debug"
TOP = "top_pg2l100h_camera_lcd"
PROJECT = "pg2l100h_camera_lcd"


def rtl_sources():
    return sorted((COMMON / "rtl").glob("*.v")) + sorted((ROOT / "rtl").glob("*.v"))


def main():
    parser = argparse.ArgumentParser(description="Build PG2L100H OV7670 FIFO + AN430 debug project")
    parser.add_argument("--pds-home", type=Path, default=Path(os.environ.get("PDS_HOME", "E:/PDS")))
    parser.add_argument("--lcd-header", choices=["J11", "J12"], default="J11")
    parser.add_argument("--create-only", action="store_true")
    parser.add_argument("--prepare-only", action="store_true", help="Prepare a portable PDS project without invoking PDS")
    args = parser.parse_args()
    shell = args.pds_home / "bin/pds_shell.exe"
    if not (COMMON / "rtl/top_camera_lcd_debug.v").is_file():
        parser.error(f"Shared MES50HP camera debug RTL is missing: {COMMON}")
    generate(args.lcd_header)
    destination = ROOT / "build" / args.lcd_header.lower()
    destination.mkdir(parents=True, exist_ok=True)
    sources = rtl_sources()
    for source in sources:
        target = destination / "rtl" / source.name
        target.parent.mkdir(exist_ok=True)
        shutil.copy2(source, target)
    for name in ["create_project.tcl", "pg2l100h_camera_lcd.fdc", "pinout.json", "wiring.csv", "WIRING.md"]:
        shutil.copy2(ROOT / name, destination / name)
    project = prepare_project(destination, sources)
    tracked = sources + [ROOT / name for name in ["create_project.tcl", "pg2l100h_camera_lcd.fdc", "generate_pins.py", "build.py", "project_file.py", "pinout.json"]]
    report = dict(success=False, hardware_programmed=False, hardware_tested=False,
                  device="Logos2/PG2L100H/-6/FBG676", top_module=TOP,
                  project_prepared=True, bitstream_requested=not (args.prepare_only or args.create_only),
                  project=project.relative_to(ROOT).as_posix(),
                  lcd_header=args.lcd_header, camera_header="J7 via 22-to-18-pin adapter",
                  reference_clock_hz=50000000, system_clock_hz=27000000,
                  lcd_clock_hz=9000000, lcd_active=[480, 272], lcd_total=[525, 286],
                  camera_format="OV7670 AL422 FIFO QVGA RGB565", stored_image=[160, 120], uart_baud=115200,
                  input_sha256={path.relative_to(ROOT.parents[1]).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                                for path in tracked})
    summary = destination / "build_summary.json"

    def save():
        summary.write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")

    started = time.time()
    save()
    steps = [("create", ["-file", "create_project.tcl", "-work_dir", ".", "-project_name", PROJECT])]
    if not args.create_only:
        steps.append(("bitstream", ["-project", str(destination / f"{PROJECT}.pds"), "-run", "gen_bit_stream"]))
    try:
        if args.prepare_only:
            print(f"Prepared: {project}", flush=True)
            return
        if not shell.is_file():
            raise RuntimeError("PDS shell missing; use --pds-home or --prepare-only")
        device_data = args.pds_home / "arch/vendor/pango/logos2/pg2l100h"
        if not device_data.is_dir():
            raise RuntimeError(f"{args.pds_home} lacks PG2L100H device data. Install a full PDS version with Logos2 support; "
                               f"the prepared project is retained at {project}")
        for name, arguments in steps:
            log = destination / f"{name}_console.log"
            print(f"PDS {name}: {log}", flush=True)
            with log.open("w", encoding="utf-8") as output:
                result = subprocess.run([str(shell), *arguments], cwd=destination,
                                        stdout=output, stderr=subprocess.STDOUT)
            text = log.read_text(encoding="utf-8", errors="replace")
            if result.returncode or re.search(r"(?m)^E:", text):
                raise RuntimeError(f"PDS {name} failed; see {log}")
        report["project"] = (destination / f"{PROJECT}.pds").relative_to(ROOT).as_posix()
        if args.create_only:
            report["project_created"] = True
            print(f"Created: {destination / (PROJECT + '.pds')}", flush=True)
            return
        bitstream = destination / f"generate_bitstream/{TOP}.sbit"
        if not bitstream.is_file() or bitstream.stat().st_mtime < started:
            raise RuntimeError("PDS did not produce a fresh bitstream")
        timing = destination / f"place_route/{TOP}_timing_summary_after_hold_fix.txt"
        if not timing.is_file() or "Design Summary : All Constraints Met." not in timing.read_text(errors="replace"):
            raise RuntimeError(f"Timing did not pass; inspect {timing}")
        report.update(success=True, timing_constraints_met=True,
                      bitstream=bitstream.relative_to(ROOT).as_posix(), bitstream_bytes=bitstream.stat().st_size,
                      bitstream_sha256=hashlib.sha256(bitstream.read_bytes()).hexdigest())
        print(f"PASS: {bitstream} ({report['bitstream_bytes']} bytes), timing constraints met", flush=True)
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        report.update(completed_utc=datetime.now(timezone.utc).isoformat(), elapsed_seconds=round(time.time()-started, 2))
        save()


if __name__ == "__main__":
    main()
