import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

from generate_pins import pin_rows


ROOT = Path(__file__).resolve().parent


def check_pins():
    rows = pin_rows()
    top = (ROOT / "rtl/top_camera_lcd_debug.v").read_text()
    declaration = top.split(");", 1)[0]
    ports = set()
    for direction, upper, lower, name in re.findall(
            r"(input|output|inout)\s+wire\s+(?:\[(\d+):(\d+)\]\s+)?(\w+)", declaration):
        if upper:
            ports.update(f"{name}[{index}]" for index in range(int(lower), int(upper)+1))
        else:
            ports.add(name)
    if ports != {row["port"] for row in rows}:
        raise AssertionError("Top-level ports do not match pin assignments")
    fdc = (ROOT / "mes50hp_camera_lcd.fdc").read_text()
    locations = dict(re.findall(r"define_attribute \{p:([^}]+)\} \{PAP_IO_LOC\} \{([^}]+)\}", fdc))
    if locations != {row["port"]: row["ball"] for row in rows}:
        raise AssertionError("FDC does not match generate_pins.py; regenerate pin assignments")
    with (ROOT / "wiring.csv").open(encoding="utf-8-sig", newline="") as source:
        if list(csv.DictReader(source)) != rows:
            raise AssertionError("CSV wiring does not match FDC source")
    return {"ports": len(ports), "external_gpio": 42, "unique_balls": len(set(locations.values()))}


def main():
    parser = argparse.ArgumentParser(description="Simulate MES50HP camera/LCD debug project")
    parser.add_argument("--iverilog", type=Path)
    parser.add_argument("--test", action="append", choices=["capture", "video", "config", "controls"])
    args = parser.parse_args()
    tool = args.iverilog or (Path(shutil.which("iverilog")) if shutil.which("iverilog") else
                            Path(os.environ.get("LOCALAPPDATA", "")) /
                            "Temp/codex-fpga-sim/mingw64/bin/iverilog.exe")
    if not tool.is_file():
        parser.error("Install Icarus Verilog and pass --iverilog with its executable path")
    tool = tool.resolve()
    environment = os.environ.copy()
    environment["PATH"] = str(tool.parent) + os.pathsep + environment.get("PATH", "")
    runtime = tool.parent / ("vvp.exe" if os.name == "nt" else "vvp")
    library = tool.parent.parent / "lib/ivl"
    compiler = [str(tool)] + (["-B", str(library)] if library.is_dir() else [])
    destination = ROOT / "validation"
    destination.mkdir(exist_ok=True)
    summary = destination / "simulation_summary.json"
    summary.write_text(json.dumps(dict(success=False), indent=2)+"\n", encoding="utf-8")
    tests = args.test or ["capture", "video", "config", "controls"]
    report = dict(success=False, pin_check=check_pins(), tests={})
    for name in tests:
        bench = ROOT / f"sim/tb_{name}.v"
        executable = destination / f"tb_{name}.vvp"
        sources = sorted((ROOT / "rtl").glob("*.v")) + [bench]
        log = destination / f"{name}.log"
        print(f"Simulating {name}: {log}", flush=True)
        with log.open("w", encoding="utf-8") as output:
            result = subprocess.run(compiler + ["-g2012", "-Wall", "-s", f"tb_{name}", "-o", str(executable)] +
                                    [str(path) for path in sources], env=environment, stdout=output, stderr=subprocess.STDOUT)
            if result.returncode:
                raise RuntimeError(f"Icarus compilation failed: {log}")
            result = subprocess.run([str(runtime), "-i", str(executable)], cwd=destination,
                                    env=environment, stdout=output, stderr=subprocess.STDOUT, timeout=180)
        text = log.read_text(encoding="utf-8", errors="replace")
        marker = f"PASS tb_{name}:"
        if result.returncode or marker not in text or "FATAL:" in text:
            raise RuntimeError(f"Simulation failed: {log}\n{text[-3000:]}")
        print(text.strip(), flush=True)
        report["tests"][name] = "passed"
    if "video" in tests:
        try:
            from PIL import Image
        except ImportError:
            print("Pillow unavailable: PPM screenshots retained")
        else:
            for name in ["lcd_colorbars", "camera_gradient"]:
                with Image.open(destination / f"{name}.ppm") as image:
                    image.save(destination / f"{name}.png")
    report["success"] = True
    report["hardware_tested"] = False
    sources = sorted((ROOT / "rtl").glob("*.v")) + sorted((ROOT / "sim").glob("*.v"))
    report["source_sha256"] = {path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                               for path in sources}
    summary.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"PASS: {len(tests)} simulations and all pin assignments", flush=True)


if __name__ == "__main__":
    main()
