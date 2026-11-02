import hashlib
import json
import os
from pathlib import Path
import zipfile


ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = ROOT.parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_files(folder):
    for current, directories, files in os.walk(folder):
        directories[:] = [name for name in directories if name not in ["build", "validation", "checkpoints", "__pycache__"]]
        for name in files:
            path = Path(current) / name
            if path.suffix.lower() in [".py", ".md", ".sv", ".v", ".c", ".h", ".s", ".ld", ".hex", ".npz", ".json", ".txt", ".pdf"]:
                yield path


def main():
    validation = ROOT / "validation"
    report = json.loads((validation / "simulation_summary.json").read_text())
    expected_tests = {"verilog", "guard", "tools", "training_data", "snapshot", "snapshot_hand", "cdc", "camera", "lcd", "npu", "soc", "soc_hand", "board"}
    if not report["success"] or set(report["tests"]) != expected_tests or report["model_sha256"] != digest(ROOT / "model/model.json"):
        raise ValueError("The current model needs a complete successful verification before packaging")
    if report.get("gesture_model_sha256") != digest(ROOT / "model/gesture/model.json"):
        raise ValueError("The gesture model changed after verification")
    stage = ROOT / "build/j11"
    manifest = json.loads((stage / "manifest.json").read_text())
    if report["inputs"] != manifest["inputs"]:
        raise ValueError("The source inputs changed after verification; rerun the complete suite")
    for group, parent in [("inputs", WORKSPACE), ("artifacts", stage)]:
        for name, expected in manifest[group].items():
            if digest(parent / name) != expected:
                raise ValueError(f"Stale project file: {name}")
    files = set(source_files(ROOT)) | set(source_files(ROOT.parent / "camera_lcd_debug"))
    files |= {WORKSPACE / name for name in manifest["inputs"]}
    files |= {stage / name for name in manifest["artifacts"]}
    files |= {stage / "manifest.json", stage / "build_summary.json", stage / "WIRING.md"}
    files |= {WORKSPACE / "fpga_mes50hp/tools/build_digit.py", ROOT.parent / "README.md"}
    files |= {WORKSPACE / "fpga_mes50hp/tools/sv2v" / name for name in ["LICENSE", "NOTICE", "README.md"]}
    for name in ["LICENSE", "LICENSE.md", "LICENSE.txt"]:
        if (WORKSPACE / name).is_file():
            files.add(WORKSPACE / name)
    for name in ["simulation_summary.json", "board_summary.json", "coremark_functional.json", "verilog.log", "cdc.log", "camera.log", "guard.log", "tools.log", "training_data.log", "snapshot.log", "snapshot_hand.log", "lcd.log", "npu.log", "soc.log", "soc_hand.log", "board.log", "coremark.log", "pds_preflight.log", "lcd_overlay.png", "numeric_examples.png", "numeric_examples.json", "gesture_examples.png", "gesture_examples.json"]:
        if (validation / name).is_file():
            files.add(validation / name)
    build = json.loads((stage / "build_summary.json").read_text())
    native_verified = bool(build.get("success") and build.get("timing_constraints_met"))
    programming_verified = False
    if native_verified:
        bitstream = stage / "generate_bitstream/top_pg2l100h_vision.sbit"
        timing = stage / "place_route/top_pg2l100h_vision_timing_summary_after_hold_fix.txt"
        if digest(bitstream) != build["bitstream_sha256"] or "Design Summary : All Constraints Met." not in timing.read_text():
            raise ValueError("The native build evidence does not match the packaged bitstream")
        files |= {bitstream, timing, stage / "device_map/run.log", stage / "place_route/run.log", stage / "bitstream_console.log"}
        hardware_summary = validation / "hardware_summary.json"
        if hardware_summary.is_file():
            hardware = json.loads(hardware_summary.read_text())
            if hardware["bitstream_sha256"] == build["bitstream_sha256"]:
                programming_verified = bool(hardware["programming"]["programming_success"])
                files.add(hardware_summary)
                evidence = ROOT / hardware["evidence_root"]
                files |= {path for path in evidence.iterdir() if path.is_file() and path.suffix in [".json", ".log", ".tcl", ".txt"]}
    destination = ROOT / "competition/NUMGUARD_project.zip"
    files = {path for path in files if path.is_file() and path != destination and path.name != "package_summary.json"}
    package_manifest = dict(scope="Verified Verilog prototype and J11 PDS project; native build and programming evidence included when verified; application hardware acceptance pending; gesture model experimental", hardware_tested=False, native_build_verified=native_verified, programming_verified=programming_verified, model_sha256=report["model_sha256"], gesture_model_sha256=report["gesture_model_sha256"], files={path.relative_to(WORKSPACE).as_posix(): digest(path) for path in sorted(files)})
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in sorted(files):
            archive.write(path, path.relative_to(WORKSPACE).as_posix())
        archive.writestr("NUMGUARD_PACKAGE_MANIFEST.json", json.dumps(package_manifest, indent=2) + "\n")
    summary = dict(path=str(destination.relative_to(WORKSPACE)), bytes=destination.stat().st_size, sha256=digest(destination), file_count=len(files), hardware_tested=False, native_build_verified=native_verified, programming_verified=programming_verified, verification_tests=sorted(expected_tests))
    (ROOT / "competition/package_summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
