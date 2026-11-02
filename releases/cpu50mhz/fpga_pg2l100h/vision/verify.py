import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

from build import ROOT, DEBUG, CLOCK_HZ, digest


def prepare_soc_vector(hand=False):
    import numpy as np
    import torch
    sys.path.insert(0, str(ROOT / "model"))
    from network import decode, integer_forward
    from camera_preprocess import skin_mask
    torch.set_num_threads(4)
    validation = ROOT / "validation"
    model_dir = ROOT / "model/gesture" if hand else ROOT / "model"
    prefix = "hand_" if hand else ""
    model = json.loads((model_dir / "model.json").read_text())
    candidates = json.loads((validation / (prefix + "reference_detections.json")).read_text())
    eligible = []
    for index, candidate in enumerate(candidates):
        if candidate is None:
            continue
        outputs = np.array([int(value, 16) for value in (validation / f"{prefix}output_{index}.hex").read_text().split()], dtype=np.uint32).view(np.int32).reshape(16, 27)
        logits = sorted((int(outputs[int(np.argmax(outputs[:, 0])), 5 + category]) for category in model["enabled_classes"]), reverse=True)
        if candidate["category"] in model["enabled_classes"] and logits[0] - logits[1] >= model.get("class_margin_threshold", 24):
            eligible.append(index)
    if not eligible:
        raise AssertionError("No digit integration vector meets the firmware quality gate")
    sample_index = max(eligible, key=lambda index: candidates[index]["objectness"])
    values = np.array([int(value, 16) for value in (validation / f"{prefix}input_{sample_index}.hex").read_text().split()], dtype=np.uint8).reshape(64, 64)
    camera = np.full((120, 160), 65535, dtype=np.uint16)
    intensity = (255 - 2 * values[2:62].astype(np.uint16))
    colors = ((intensity >> 3) << 11) | ((intensity >> 2) << 5) | (intensity >> 3)
    if hand:
        colors = np.where(values[2:62] != 0, 0xe50e, 65535).astype(np.uint16)
    camera[:, 16:144] = colors.repeat(2, axis=0).repeat(2, axis=1)
    sampled = camera[::2, 16:144:2].astype(np.uint32)
    red = ((sampled >> 11) << 3) | (sampled >> 13)
    green = (((sampled >> 5) & 63) << 2) | ((sampled >> 9) & 3)
    blue = ((sampled & 31) << 3) | ((sampled >> 2) & 7)
    pixels = np.zeros((64, 64), dtype=np.uint8)
    pixels[2:62] = (255 - ((red + 2 * green + blue) >> 2)) >> 1
    if hand:
        pixels[2:62] = skin_mask(red, green, blue).astype(np.uint8) * 127
    with np.load(model_dir / "micro_yolo.npz", allow_pickle=False) as contents:
        arrays = dict(contents)
    result = integer_forward(pixels, arrays)
    candidate = decode(result, model["enabled_classes"], model["object_threshold"])
    if not candidate:
        raise AssertionError("Camera integration vector must contain a model detection")
    selected = result.reshape(16, 27)[int(np.argmax(result[:, :, 0]))]
    logits = sorted((int(selected[5 + category]) for category in model["enabled_classes"]), reverse=True)
    if logits[0] - logits[1] < model.get("class_margin_threshold", 24):
        raise AssertionError("Camera quantization moved the vector outside the firmware quality gate")
    left, top, right, bottom = candidate["box"]
    expected = [1, candidate["category"], min(399, max(80, 112 + 4 * left)), min(255, max(16, 8 + 4 * top)),
                min(399, max(80, 112 + 4 * right)), min(255, max(16, 8 + 4 * bottom)), 1769238, candidate["objectness"]]
    (validation / (prefix + "camera.hex")).write_text("".join(f"{value:04x}\n" for value in camera.reshape(-1)), encoding="ascii")
    (validation / (prefix + "model_input.hex")).write_text("".join(f"{value:02x}\n" for value in pixels.reshape(-1)), encoding="ascii")
    (validation / (prefix + "soc_expected.hex")).write_text("".join(f"{value:08x}\n" for value in expected), encoding="ascii")
    (validation / (prefix + "soc_reference.json")).write_text(json.dumps(dict(detection=candidate, lcd_box=expected[2:6]), indent=2) + "\n", encoding="utf-8")
    return candidate


def run_icarus(name, stage, destination, tool):
    sources = {
        "snapshot": ["vision_snapshot.v"], "lcd": ["vision_lcd.v"], "npu": ["vision_npu.v"],
        "snapshot_hand": ["vision_snapshot.v"],
        "cdc": ["vision_video_bridge.v", "vision_framebuffer.v"], "camera": ["camera_dvp_capture.v"],
        "soc": ["vision_soc.v", "vision_npu.v", "vision_snapshot.v", "debug_keys.v", "debug_uart.v"],
        "coremark": ["vision_soc.v", "vision_npu.v", "vision_snapshot.v", "debug_keys.v", "debug_uart.v"],
    }[name]
    if name in ["soc", "coremark"]:
        sources += [path.name for path in (ROOT / "rtl/cpu").glob("*.v")]
    environment = os.environ.copy()
    environment["PATH"] = str(tool.parent) + os.pathsep + environment.get("PATH", "")
    temporary = destination / "tmp"
    temporary.mkdir(exist_ok=True)
    environment["TMPDIR"] = str(temporary)
    environment["TMP"] = str(temporary)
    output = destination / (name + ".vvp")
    testbench = "tb_camera_dvp" if name == "camera" else "tb_" + name
    command = [str(tool), "-B", str(tool.parent.parent / "lib/ivl"), "-g2012", "-s", testbench, "-o", str(output)]
    command += [str(stage / "rtl" / source) for source in sources] + [str(ROOT / "sim" / (testbench + ".v"))]
    if name == "snapshot_hand":
        command.append(str(ROOT / "sim/tb_snapshot.v"))
    with (destination / (name + "_compile.log")).open("w") as log:
        result = subprocess.run(command, cwd=stage, env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=60)
    if result.returncode:
        raise RuntimeError(f"{name} compile failed; see {destination / (name + '_compile.log')}")
    with (destination / (name + ".log")).open("w") as log:
        result = subprocess.run([str(tool.parent / "vvp.exe"), "-i", str(output), "+vectors=" + destination.as_posix(),
                                 "+image=" + (destination / "lcd_overlay.ppm").as_posix()], cwd=stage, env=environment,
                                stdout=log, stderr=subprocess.STDOUT, timeout=240)
    text = (destination / (name + ".log")).read_text(errors="replace")
    if result.returncode or "PASS " + name not in text or "FATAL" in text:
        raise RuntimeError(f"{name} simulation failed; see {destination / (name + '.log')}")
    return [line for line in text.splitlines() if line.startswith("PASS ")]


def run_verilog_syntax(stage, destination, tool, pds_home):
    if list((ROOT / "rtl").rglob("*.sv")) or list((stage / "rtl").glob("*.sv")):
        raise AssertionError("The active project must contain only Verilog hardware sources")
    environment = os.environ.copy()
    temporary = destination / "tmp"
    temporary.mkdir(exist_ok=True)
    environment.update(TMP=str(temporary), TEMP=str(temporary), TMPDIR=str(temporary))
    sources = sorted((stage / "rtl").glob("*.v")) + [pds_home / "arch/vendor/pango/verilog/simulation/GTP_GPLL.v"]
    command = [str(tool), "-B", str(tool.parent.parent / "lib/ivl"), "-g2005", "-t", "null", "-s", "top_pg2l100h_vision", *map(str, sources)]
    result = subprocess.run(command, cwd=stage, env=environment, capture_output=True, text=True, timeout=60)
    (destination / "verilog.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    if result.returncode:
        raise RuntimeError("Verilog-2005 compile failed; see validation/verilog.log")
    return [f"PASS verilog all {len(sources) - 1} active RTL files compile with -g2005 and the Pango PLL model"]


def run_board(stage, destination, vivado_home, pds_home, test_name="board"):
    work = destination / "xsim" / test_name
    work.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    temporary = destination / "tmp"
    temporary.mkdir(exist_ok=True)
    environment.update(TMP=str(temporary), TEMP=str(temporary), TMPDIR=str(temporary))
    model = pds_home / "arch/vendor/pango/verilog/simulation/GTP_GPLL.v"
    sources = sorted((stage / "rtl").glob("*.v")) + [model, ROOT / "sim" / ("tb_" + test_name + ".v")]
    if test_name == "soc_hand":
        sources.append(ROOT / "sim/tb_soc.v")
    steps = [("xvlog", ["--sv", *map(str, sources)]),
             ("xelab", ["tb_" + test_name, "-s", "vision_" + test_name, "-debug", "typical"]),
             ("xsim", ["vision_" + test_name, "-runall"])]
    for name, arguments in steps:
        with (work / (name + "_console.log")).open("w") as log:
            result = subprocess.run([str(vivado_home / "bin" / (name + ".bat")), *arguments], cwd=stage, env=environment,
                                    stdout=log, stderr=subprocess.STDOUT, timeout=480 if name == "xsim" else 180)
        if result.returncode:
            raise RuntimeError(f"{test_name} {name} failed; see {work / (name + '_console.log')}")
    text = (work / "xsim_console.log").read_text(errors="replace")
    (destination / (test_name + ".log")).write_text(text, encoding="utf-8")
    if "PASS " + test_name not in text or "Fatal:" in text:
        raise RuntimeError(f"{test_name} simulation failed; see {destination / (test_name + '.log')}")
    return [line for line in text.splitlines() if line.startswith("PASS ")]


def run_host(name, destination):
    environment = os.environ.copy()
    temporary = destination / "tmp"
    temporary.mkdir(exist_ok=True)
    environment.update(TMP=str(temporary), TEMP=str(temporary), TMPDIR=str(temporary))
    if name == "guard":
        compiler = os.environ.get("HOST_GCC") or shutil.which("gcc")
        if not compiler:
            raise FileNotFoundError("Native GCC required for the numeric state-machine test; set HOST_GCC")
        output = destination / "numeric_guard_test.exe"
        subprocess.run([compiler, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", str(ROOT / "sim/test_numeric_guard.c"), "-o", str(output)], check=True, env=environment)
        command = [str(output)]
    else:
        command = [sys.executable, str(ROOT / "sim" / ("test_training_data.py" if name == "training_data" else "test_tools.py"))]
    result = subprocess.run(command, capture_output=True, text=True, timeout=60, env=environment)
    (destination / (name + ".log")).write_text(result.stdout + result.stderr, encoding="utf-8")
    if result.returncode:
        raise RuntimeError(f"{name} test failed: {result.stdout}{result.stderr}")
    return [line for line in result.stdout.splitlines() if line.startswith("PASS ")]


def main():
    parser = argparse.ArgumentParser(description="Verify the portable vision project and its trained model/RTL/firmware")
    parser.add_argument("--test", action="append", choices=["verilog", "guard", "tools", "training_data", "snapshot", "snapshot_hand", "lcd", "npu", "soc", "soc_hand", "board", "cdc", "camera"])
    parser.add_argument("--iverilog", type=Path, default=Path(os.environ.get("LOCALAPPDATA", "")) / "Temp/codex-fpga-sim/mingw64/bin/iverilog.exe")
    parser.add_argument("--vivado-home", type=Path, default=Path(os.environ.get("VIVADO_HOME", "E:/Vivado/2018.3")))
    parser.add_argument("--pds-home", type=Path, default=Path(os.environ.get("PDS_HOME", "E:/PDS")))
    args = parser.parse_args()
    stage = ROOT / "build/j11"
    destination = ROOT / "validation"
    destination.mkdir(exist_ok=True)
    for source in (ROOT / "model/vectors").glob("*"):
        shutil.copy2(source, destination / source.name)
    for source in (ROOT / "model/gesture/vectors").glob("*"):
        shutil.copy2(source, destination / ("hand_" + source.name))
    subprocess.run([sys.executable, str(ROOT / "build.py"), "--check"], check=True)
    manifest = json.loads((stage / "manifest.json").read_text())
    report = dict(success=False, hardware_tested=False, device=manifest["device"], clock_hz=CLOCK_HZ, tests={},
                  model_sha256=digest(ROOT / "model/model.json"), gesture_model_sha256=digest(ROOT / "model/gesture/model.json"), inputs=manifest["inputs"],
                  npu_cycles_per_inference=1769238, npu_compute_seconds=1769238 / CLOCK_HZ,
                  target_synthesis_complete=False, target_timing_complete=False)
    sys.path.insert(0, str(DEBUG))
    from project_file import parse_project
    project = parse_project((stage / "pg2l100h_vision.pds").read_text())
    forms = []

    def visit(form):
        forms.append(form)
        for child in form:
            if isinstance(child, list):
                visit(child)

    visit(project)
    for part in [["_family", "Logos2"], ["_device", "PG2L100H"], ["_speedgrade", "-6"], ["_package", "FBG676"]]:
        if part not in forms:
            raise AssertionError("Incorrect target device in project")
    for form in [form for form in forms if form[0] == "_file"]:
        if [child[0] for child in form if isinstance(child, list)] != ["_format", "_timespec"]:
            raise AssertionError("PDS file registration lacks required metadata")
    from generate_pins import pin_rows
    if json.loads((stage / "pinout.json").read_text()) != dict(lcd_header="J11", camera_interface="dvp18", pins=pin_rows("J11", "dvp18")):
        raise AssertionError("J11 pin assignment mismatch")
    tests = args.test or ["verilog", "guard", "tools", "training_data", "snapshot", "snapshot_hand", "cdc", "camera", "lcd", "npu", "soc", "soc_hand", "board"]
    try:
        if "soc" in tests:
            report["soc_reference"] = prepare_soc_vector()
        if "soc_hand" in tests:
            report["soc_hand_reference"] = prepare_soc_vector(hand=True)
        for name in tests:
            started = time.time()
            print(f"Testing {name}...", flush=True)
            if name == "verilog":
                messages = run_verilog_syntax(stage, destination, args.iverilog.resolve(), args.pds_home)
            elif name in ["guard", "tools", "training_data"]:
                messages = run_host(name, destination)
            else:
                messages = run_board(stage, destination, args.vivado_home, args.pds_home, name) if name in ["board", "soc", "soc_hand"] else run_icarus(name, stage, destination, args.iverilog.resolve())
            report["tests"][name] = dict(success=True, elapsed_seconds=round(time.time() - started, 2), checks=messages)
            print("\n".join(messages), flush=True)
        if "lcd" in tests:
            from PIL import Image
            with Image.open(destination / "lcd_overlay.ppm") as image:
                image.save(destination / "lcd_overlay.png")
        report["success"] = True
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        report["completed_utc"] = datetime.now(timezone.utc).isoformat()
        summary_name = "board_summary.json" if tests == ["board"] else "simulation_summary.json"
        (destination / summary_name).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        if "board" in tests:
            board_report = dict(report, success="board" in report["tests"], tests={name: value for name, value in report["tests"].items() if name == "board"})
            (destination / "board_summary.json").write_text(json.dumps(board_report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
