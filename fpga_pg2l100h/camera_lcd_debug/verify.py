import argparse
import csv
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

from build import COMMON, ROOT, rtl_sources
from generate_pins import pin_rows
from project_file import parse_project


def check_pins():
    selected = json.loads((ROOT / "pinout.json").read_text(encoding="utf-8"))["lcd_header"]
    rows = pin_rows(selected)
    declaration = (ROOT / "rtl/top_pg2l100h_camera_lcd.v").read_text().split(");", 1)[0]
    ports = set()
    for direction, upper, lower, name in re.findall(
            r"(input|output|inout)\s+wire\s+(?:\[(\d+):(\d+)\]\s+)?(\w+)", declaration):
        if upper:
            ports.update(f"{name}[{index}]" for index in range(int(lower), int(upper)+1))
        else:
            ports.add(name)
    if ports != {row["port"] for row in rows}:
        raise AssertionError("Top-level ports do not match pin assignments")
    fdc = (ROOT / "pg2l100h_camera_lcd.fdc").read_text()
    attributes = {(port, attribute): value for port, attribute, value in re.findall(
        r"define_attribute \{p:([^}]+)\} \{([^}]+)\} \{([^}]+)\}", fdc)}
    for row in rows:
        expected = dict(PAP_IO_LOC=row["ball"], PAP_IO_DIRECTION=row["direction"], PAP_IO_VCCIO=row["voltage"],
                        PAP_IO_STANDARD="LVCMOS15" if row["port"] == "sys_clk" else "LVCMOS33")
        for attribute, value in expected.items():
            if attributes.get((row["port"], attribute)) != value:
                raise AssertionError(f"FDC attribute mismatch: {row['port']} {attribute}")
    with (ROOT / "wiring.csv").open(encoding="utf-8-sig", newline="") as source:
        if list(csv.DictReader(source)) != rows:
            raise AssertionError("CSV wiring does not match constraints")
    if json.loads((ROOT / "pinout.json").read_text(encoding="utf-8"))["pins"] != rows:
        raise AssertionError("JSON wiring does not match constraints")
    for header in ["J11", "J12"]:
        alternate = pin_rows(header)
        camera = [row for row in alternate if row["board_connector"] == "J7"]
        lcd = [row for row in alternate if row["board_connector"] == header]
        if {int(row["board_pin"]) for row in camera} != set(range(2, 19)) - {6}:
            raise AssertionError("Camera port accidentally includes power or ground")
        if {int(row["board_pin"]) for row in lcd} != set(range(3, 35)):
            raise AssertionError("LCD GPIO must avoid rails and J11 NC pins")
        for row in camera:
            if row["port"].startswith("cam_data["):
                index = int(row["port"][9:-1])
                if int(row["peripheral_pin"]) != 14-index:
                    raise AssertionError("OV7670 data pin order reversed")
    return dict(lcd_header=selected, ports=60, unique_balls=60, external_gpio=48,
                both_header_variants_checked=True, physical_wiring_verified=False)


def simulate_board(sources, vivado_home, destination):
    work = destination / "xsim"
    work.mkdir(exist_ok=True)
    steps = [
        ("xvlog", ["--sv", *[str(path) for path in sources]]),
        ("xelab", ["tb_board", "-s", "pg2l100h_board", "-debug", "typical"]),
        ("xsim", ["pg2l100h_board", "-runall"]),
    ]
    for name, arguments in steps:
        executable = vivado_home / "bin" / (name + (".bat" if os.name == "nt" else ""))
        if not executable.is_file():
            raise RuntimeError(f"Vivado Xsim tool not found: {executable}; set --vivado-home")
        log = work / f"{name}_console.log"
        with log.open("w", encoding="utf-8") as output:
            result = subprocess.run([str(executable), *arguments], cwd=work,
                                    stdout=output, stderr=subprocess.STDOUT, timeout=180)
        if result.returncode:
            raise RuntimeError(f"{name} failed; see {log}")
    text = (work / "xsim_console.log").read_text(encoding="utf-8", errors="replace")
    (destination / "board.log").write_text(text, encoding="utf-8")
    return text


def check_prepared_projects():
    checked = []
    for header in ["J11", "J12"]:
        directory = ROOT / "build" / header.lower()
        project = directory / "pg2l100h_camera_lcd.pds"
        if not project.is_file():
            continue
        forms = []

        def visit(form):
            forms.append(form)
            for child in form:
                if isinstance(child, list):
                    visit(child)

        visit(parse_project(project.read_text(encoding="utf-8")))
        for tag, value in [("_family", "Logos2"), ("_device", "PG2L100H"), ("_speedgrade", "-6"), ("_package", "FBG676")]:
            if [tag, value] not in forms:
                raise AssertionError(f"Prepared project has incorrect device: {project}")
        registered_files = [form for form in forms if form[0] == "_file"]
        for form in registered_files:
            metadata = [child for child in form if isinstance(child, list)]
            if [child[0] for child in metadata] != ["_format", "_timespec"]:
                raise AssertionError(f"Prepared project file entry lacks required PDS metadata: {form[1]}")
            datetime.fromisoformat(json.loads(metadata[1][1]))
        files = [json.loads(form[1]) for form in registered_files]
        expected = {"rtl/"+source.name for source in rtl_sources()} | {"pg2l100h_camera_lcd.fdc"}
        if set(files) != expected or len(files) != len(expected):
            raise AssertionError(f"Prepared project has incorrect source registration: {project}")
        if any(form[0] in ["_output", "_db_output"] or (form[0] == "_gci_state" and form[1] != ["_integer", "0"]) for form in forms):
            raise AssertionError(f"Prepared project contains stale compile state: {project}")
        for source in rtl_sources():
            if (directory / "rtl" / source.name).read_bytes() != source.read_bytes():
                raise AssertionError(f"Prepared project RTL is stale: {source.name}; rerun build.py --prepare-only")
        pinout = json.loads((directory / "pinout.json").read_text(encoding="utf-8"))
        if pinout != dict(lcd_header=header, pins=pin_rows(header)):
            raise AssertionError(f"Prepared project uses the wrong LCD header: {project}")
        constraints = (directory / "pg2l100h_camera_lcd.fdc").read_text()
        balls = dict(re.findall(r"define_attribute \{p:([^}]+)\} \{PAP_IO_LOC\} \{([^}]+)\}", constraints))
        if balls != {row["port"]: row["ball"] for row in pin_rows(header)}:
            raise AssertionError(f"Prepared project constraints are stale: {project}")
        checked.append(header)
    return checked


def main():
    parser = argparse.ArgumentParser(description="Verify PG2L100H camera/LCD pins and RTL")
    parser.add_argument("--iverilog", type=Path)
    parser.add_argument("--pds-home", type=Path, default=Path(os.environ.get("PDS_HOME", "E:/PDS")))
    parser.add_argument("--vivado-home", type=Path, default=Path(os.environ.get("VIVADO_HOME", "E:/Vivado/2018.3")))
    parser.add_argument("--test", action="append", choices=["capture", "video", "config", "controls", "board"])
    args = parser.parse_args()
    tool = args.iverilog or (Path(shutil.which("iverilog")) if shutil.which("iverilog") else
                            Path(os.environ.get("LOCALAPPDATA", "")) / "Temp/codex-fpga-sim/mingw64/bin/iverilog.exe")
    if not tool.is_file():
        parser.error("Install Icarus Verilog or pass --iverilog with its executable path")
    tool = tool.resolve()
    runtime = tool.parent / ("vvp.exe" if os.name == "nt" else "vvp")
    library = tool.parent.parent / "lib/ivl"
    compiler = [str(tool)] + (["-B", str(library)] if library.is_dir() else [])
    environment = os.environ.copy()
    environment["PATH"] = str(tool.parent) + os.pathsep + environment.get("PATH", "")
    destination = ROOT / "validation"
    destination.mkdir(exist_ok=True)
    summary = destination / "simulation_summary.json"
    report = dict(success=False, hardware_tested=False, tests={})
    tests = args.test or ["capture", "video", "config", "controls", "board"]
    try:
        report["pin_check"] = check_pins()
        report["prepared_projects_checked"] = check_prepared_projects()
        for name in tests:
            bench = (ROOT if name == "board" else COMMON) / f"sim/tb_{name}.v"
            sources = rtl_sources() + [bench]
            if name == "board":
                model = args.pds_home / "arch/vendor/pango/verilog/simulation/GTP_GPLL.v"
                if not model.is_file():
                    parser.error(f"Pango PLL simulation model not found: {model}")
                sources.append(model)
            executable = destination / f"tb_{name}.vvp"
            log = destination / f"{name}.log"
            print(f"Simulating {name}: {log}", flush=True)
            if name == "board":
                text = simulate_board(sources, args.vivado_home, destination)
                report["board_engine"] = "Vivado Xsim with Pango GTP_GPLL model"
                report["pll_model_sha256"] = hashlib.sha256(model.read_bytes()).hexdigest()
            else:
                with log.open("w", encoding="utf-8") as output:
                    result = subprocess.run(compiler + ["-g2012", "-Wall", "-s", f"tb_{name}", "-o", str(executable)] +
                                            [str(path) for path in sources], env=environment,
                                            stdout=output, stderr=subprocess.STDOUT)
                    if result.returncode:
                        raise RuntimeError(f"Icarus compilation failed; see {log}")
                    result = subprocess.run([str(runtime), "-i", str(executable)], cwd=destination, env=environment,
                                            stdout=output, stderr=subprocess.STDOUT, timeout=180)
                text = log.read_text(encoding="utf-8", errors="replace")
                if result.returncode:
                    raise RuntimeError(f"Icarus simulation failed; see {log}")
            if f"PASS tb_{name}:" not in text or "FATAL:" in text or "Fatal:" in text or "GTP_GPLL error" in text:
                raise RuntimeError(f"Simulation failed: {log}\n{text[-2000:]}")
            report["tests"][name] = "passed"
            print(next(line for line in text.splitlines() if line.startswith("PASS tb_")), flush=True)
        if "video" in tests:
            try:
                from PIL import Image
            except ImportError:
                print("Pillow unavailable: PPM previews retained", flush=True)
            else:
                for name in ["lcd_colorbars", "camera_gradient"]:
                    with Image.open(destination / f"{name}.ppm") as image:
                        image.save(destination / f"{name}.png")
        report["success"] = True
        print(f"PASS: {len(tests)} simulations and 60 pin assignments", flush=True)
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        sources = rtl_sources() + sorted((COMMON / "sim").glob("*.v")) + sorted((ROOT / "sim").glob("*.v"))
        report["source_sha256"] = {path.relative_to(ROOT.parents[1]).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                                   for path in sources}
        summary.write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")


if __name__ == "__main__":
    main()
