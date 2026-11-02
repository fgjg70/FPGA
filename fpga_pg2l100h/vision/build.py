import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parent
WORKSPACE = ROOT.parents[1]
MES = WORKSPACE / "fpga_mes50hp"
DEBUG = ROOT.parent / "camera_lcd_debug"
TOP = "top_pg2l100h_vision"
PROJECT = "pg2l100h_vision"
CLOCKS = json.loads((ROOT / "clock_config.json").read_text())
CLOCK_HZ = CLOCKS["system_clock_hz"]
CPU_CLOCK_HZ = CLOCKS["cpu_clock_hz"]
NPU_CLOCK_HZ = CLOCKS["npu_clock_hz"]
if CLOCK_HZ != 50000000 or NPU_CLOCK_HZ != CLOCK_HZ or CPU_CLOCK_HZ != 125000000:
    raise ValueError("This clock implementation requires CPU 125 MHz and peripherals/NPU 50 MHz")
sys.path.insert(0, str(DEBUG))
from generate_pins import generate
from project_file import prepare_project
sys.path.insert(0, str(MES / "tools"))
from build_digit import find_gcc, write_hex
sys.path.insert(0, str(ROOT / "model"))
from make_font import generate as generate_font
from gesture_standard import HAND_INDICES, HAND_NAMES, STANDARD_ID, definition


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def core_sources():
    return sorted((ROOT / "rtl/cpu").glob("*.v"))


def input_files(profile="numeric"):
    common = [MES / "camera_lcd_debug/rtl" / (name + ".v") for name in
              ["camera_config", "camera_sccb", "debug_keys", "debug_uart"]]
    local = sorted((ROOT / "rtl").glob("*.v"))
    paths = core_sources() + common + local + [DEBUG / "rtl/pg2l100h_clock.v", DEBUG / "generate_pins.py", DEBUG / "project_file.py", ROOT / "build.py"]
    paths += [ROOT / "firmware" / name for name in ["start.S", "numeric_main.c", "numeric_guard.h", "link.ld"]]
    paths += [ROOT / "clock_config.json", ROOT / "rtl/cpu/provenance.json"]
    paths += [ROOT / "model/gesture_standard.py"]
    paths += [ROOT / "model" / name for name in ["weights.hex", "biases.hex", "shifts.hex", "micro_yolo.npz", "model.json", "font5x7.hex", "make_font.py"]]
    paths += [ROOT / "model/gesture" / name for name in ["weights.hex", "biases.hex", "shifts.hex", "micro_yolo.npz", "model.json", "LICENSE.txt"]]
    if profile == "coremark":
        sys.path.insert(0, str(ROOT / "competition"))
        from coremark import sources, FILES
        paths += [sources() / name for name in FILES]
        paths += [ROOT / "competition" / name for name in ["coremark.py", "core_portme.h", "core_portme.c"]]
    return paths


def gesture_model(directory=None):
    model_directory = ROOT / "model/gesture" if directory is None else Path(directory)
    model = json.loads((model_directory / "model.json").read_text())
    count = len(model["enabled_classes"])
    expected = HAND_INDICES[:count]
    if count not in [9, 10] or model["enabled_classes"] != sorted(expected) or model["input"] != [64, 64, 1] or model["grid"] != [4, 4]:
        raise ValueError("The gesture bank requires legacy 1-9 or northern-reference 1-10 and the fixed NPU architecture")
    if any(model["classes"][index] != name for index, name in zip(expected, HAND_NAMES)):
        raise ValueError("Gesture channel names do not match the numeric hand mapping")
    if count == 10 and (model.get("gesture_standard") != STANDARD_ID or model.get("gesture_convention") != definition()):
        raise ValueError("The ten-class bank must be trained for the user's crossed-index-finger ten convention")
    for name, expected in model["sha256"].items():
        if digest(model_directory / name) != expected:
            raise ValueError(f"Gesture model file hash mismatch: {name}")
    return model


def build_firmware(destination, gcc, model, profile="numeric", iterations=6000):
    firmware = destination / "firmware"
    firmware.mkdir(exist_ok=True)
    (firmware / "platform_clock.h").write_text(f"#define CLOCK_HZ {CLOCK_HZ}u\n#define CPU_CLOCK_HZ {CPU_CLOCK_HZ}u\n#define NPU_CLOCK_HZ {NPU_CLOCK_HZ}u\n", encoding="ascii")
    class_mask = sum(1 << category for category in model["enabled_classes"])
    (firmware / "model_info.h").write_text(f"#define MODEL_CLASS_MASK 0x{class_mask:08x}u\n#define MODEL_OBJECT_THRESHOLD {model['object_threshold']}\n#define MODEL_CLASS_MARGIN {model.get('class_margin_threshold', 24)}\n#define MODEL_EMPTY_SCORE {model.get('empty_threshold', 40)}\n", encoding="ascii")
    gesture = gesture_model()
    with (firmware / "model_info.h").open("a", encoding="ascii") as header:
        header.write(f"#define GESTURE_OBJECT_THRESHOLD {gesture['object_threshold']}\n#define GESTURE_CLASS_MARGIN {gesture.get('class_margin_threshold', 24)}\n#define GESTURE_EMPTY_SCORE {gesture.get('empty_threshold', 40)}\n")
        count = len(gesture["enabled_classes"])
        header.write(f"#define GESTURE_DIGIT_MAX {count}\nstatic const unsigned char gesture_class_indices[GESTURE_DIGIT_MAX] = {{" + ", ".join(str(index) for index in HAND_INDICES[:count]) + "};\n")
    suffix = gcc.suffix
    prefix = gcc.name.removesuffix("gcc" + suffix)
    common = [str(gcc), "-march=rv32im", "-mabi=ilp32", "-O2", "-ffreestanding", "-fno-builtin", "-fno-strict-aliasing",
              "-fno-stack-protector", "-fno-pic", "-msmall-data-limit=0", "-mno-relax", "-Wall", "-Wextra", "-Werror", "-I", str(firmware)]
    objects = []
    if profile == "coremark":
        sys.path.insert(0, str(ROOT / "competition"))
        from coremark import compile_objects
        objects = compile_objects(firmware, gcc, common, iterations)
    else:
        for name in ["start.S", "numeric_main.c"]:
            output = firmware / (Path(name).stem + ".o")
            subprocess.run(common + ["-c", str(ROOT / "firmware" / name), "-o", str(output)], check=True)
            objects.append(str(output))
    elf = firmware / "vision.elf"
    subprocess.run([str(gcc.with_name(prefix + "ld" + suffix)), "-m", "elf32lriscv", "--no-relax", "-T", str(ROOT / "firmware/link.ld"),
                    "-Map", str(firmware / "vision.map"), *objects, "-o", str(elf)], check=True)
    sizes = {}
    for section, name, fill in [(".text", "vision_imem", "00000013"), (".data", "vision_dmem", "00000000")]:
        binary = firmware / (name + ".bin")
        subprocess.run([str(gcc.with_name(prefix + "objcopy" + suffix)), "-O", "binary", "-j", section, str(elf), str(binary)], check=True)
        sizes[name + "_bytes"] = write_hex(binary, firmware / (name + ".hex"), fill)
    for name, value, count in [("bht_init.hex", "1", 8192), ("btb_zero.hex", "0", 512), ("regfile_zero.hex", "00000000", 32)]:
        (firmware / name).write_text((value + "\n") * count, encoding="ascii")
    return sizes


def main():
    parser = argparse.ArgumentParser(description="Build PG2L100H RISC-V camera/LCD/INT8 MicroYOLO")
    parser.add_argument("--lcd-header", choices=["J11", "J12"], default="J11")
    parser.add_argument("--pds-home", type=Path, default=Path(os.environ.get("PDS_HOME", "E:/PDS")))
    parser.add_argument("--gcc")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--profile", choices=["numeric", "coremark"], default="numeric")
    parser.add_argument("--iterations", type=int, default=6000)
    args = parser.parse_args()
    if args.iterations < 1:
        parser.error("--iterations must be positive")
    destination = ROOT / "build" / (args.lcd_header.lower() if args.profile == "numeric" else "coremark_" + args.lcd_header.lower())
    manifest_path = destination / "manifest.json"
    if args.check:
        manifest = json.loads(manifest_path.read_text())
        for group, parent in [("inputs", WORKSPACE), ("artifacts", destination)]:
            for name, expected in manifest[group].items():
                if digest(parent / name) != expected:
                    raise RuntimeError(f"Stale {group}: {name}; rerun build.py --prepare-only")
        print(f"PASS: {args.lcd_header} sources, model, firmware and portable project hashes match")
        return
    destination.mkdir(parents=True, exist_ok=True)
    (destination / "rtl").mkdir(exist_ok=True)
    (destination / "model").mkdir(exist_ok=True)
    generate_font(ROOT / "model/font5x7.hex")
    model = json.loads((ROOT / "model/model.json").read_text())
    if args.profile == "numeric" and model["enabled_classes"] != list(range(12, 22)):
        raise ValueError("NUMGUARD requires the ten-digit profile; select the numeric model before building")
    if model["input"] != [64, 64, 1] or model["grid"] != [4, 4] or len(model["classes"]) != 22:
        raise ValueError("Model architecture does not match this NPU")
    for name, expected in model["sha256"].items():
        if digest(ROOT / "model" / name) != expected:
            raise ValueError(f"Model file hash mismatch: {name}")
    gesture = gesture_model()
    generate(args.lcd_header, destination, system_clock_hz=CLOCK_HZ, camera_interface="dvp18", cpu_clock_hz=CPU_CLOCK_HZ)
    sizes = build_firmware(destination, find_gcc(args.gcc), model, args.profile, args.iterations)
    rtl = []
    for source in input_files():
        if source.suffix == ".v":
            target = destination / "rtl" / source.name
            shutil.copy2(source, target)
            rtl.append(target)
    for stale in (destination / "rtl").glob("*"):
        if stale.suffix in [".v", ".sv"] and stale not in rtl:
            stale.unlink()
    for name, count in [("weights.hex", 32768), ("biases.hex", 256), ("shifts.hex", 6)]:
        banks = [(directory / name).read_text().splitlines() for directory in [ROOT / "model", ROOT / "model/gesture"]]
        if any(len(bank) != count for bank in banks):
            raise ValueError(f"Incorrect model-bank ROM size: {name}")
        (destination / "model" / name).write_text("\n".join(banks[0] + banks[1]) + "\n", encoding="ascii")
    for name in ["font5x7.hex"]:
        shutil.copy2(ROOT / "model" / name, destination / "model" / name)
    shutil.copy2(ROOT / "model/model.json", destination / "model/label_model.json")
    shutil.copy2(ROOT / "model/gesture/model.json", destination / "model/gesture_model.json")
    shutil.copy2(ROOT / "model/gesture/LICENSE.txt", destination / "model/GESTURES_LICENSE.txt")
    deployment = dict(banks=[dict(name="label", model_sha256=digest(ROOT / "model/model.json")),
                             dict(name="hand", model_sha256=digest(ROOT / "model/gesture/model.json"))],
                      padded_weight_rom_bytes=65536, padded_bias_rom_bytes=2048, runtime_mode_register="0xa100005c",
                      available_mode_mask=3, capabilities_register="0xa1000064",
                      application_modes=[dict(id=0, name="handwrite", model_bank=0, available=True, classes=10),
                                         dict(id=1, name="gesture", model_bank=1, available=True, classes=len(gesture["enabled_classes"])),
                                         dict(id=2, name="coco80", model_bank=None, available=False, classes=80,
                                              reason="COCO network operators and calibrated weights are not deployed")],
                      rom_sha256={name: digest(destination / "model" / name) for name in ["weights.hex", "biases.hex", "shifts.hex"]})
    (destination / "model/deployment.json").write_text(json.dumps(deployment, indent=2) + "\n", encoding="utf-8")
    (destination / "model/model.json").write_text(json.dumps(deployment, indent=2) + "\n", encoding="utf-8")
    project = prepare_project(destination, rtl, TOP, PROJECT if args.profile == "numeric" else "pg2l100h_coremark")
    script = 'set project_dir [file dirname [file normalize [info script]]]\ncd $project_dir\nset_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
    script += "".join(f"add_design [file join $project_dir rtl {source.name}]\n" for source in rtl)
    script += f'add_constraint [file join $project_dir pg2l100h_camera_lcd.fdc]\nif {{![llength [info commands open_project]]}} {{\n    compile -top_module {TOP} -compiler_directives {{SYNTHESIS}}\n}}\n'
    (destination / "create_project.tcl").write_text(script, encoding="ascii")
    artifacts = [project, destination / "create_project.tcl", destination / "pg2l100h_camera_lcd.fdc", destination / "pinout.json", *rtl]
    artifacts += list((destination / "firmware").glob("*.hex")) + list((destination / "firmware").glob("*.h")) + list((destination / "model").glob("*"))
    manifest = dict(top=TOP, device="Logos2/PG2L100H/-6/FBG676", clock_hz=CLOCK_HZ, clocks=CLOCKS, camera_interface="dvp18", hdl="Verilog-2005", lcd_header=args.lcd_header,
                    profile=args.profile, inputs={path.relative_to(WORKSPACE).as_posix(): digest(path) for path in input_files(args.profile)},
                    artifacts={path.relative_to(destination).as_posix(): digest(path) for path in artifacts}, **sizes)
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    report = dict(project_prepared=True, success=False, hardware_tested=False, top=TOP, device=manifest["device"],
                  clock_hz=CLOCK_HZ, cpu_clock_hz=CPU_CLOCK_HZ, npu_clock_hz=NPU_CLOCK_HZ, camera_interface="dvp18", camera_mclk_hz=CLOCKS["camera_mclk_hz"], profile=args.profile, enabled_classes=[model["classes"][index] for index in model["enabled_classes"]] if args.profile == "numeric" else [],
                  gesture_classes=HAND_NAMES[:len(gesture["enabled_classes"])],
                  gesture_standard=gesture.get("gesture_standard", "legacy_public_mixed_1_9"),
                  model_weight_bytes=model["weight_bytes"] + gesture["weight_bytes"], model_banks=2,
                  application_modes=deployment["application_modes"], available_mode_mask=3, coco80_deployed=False, **sizes)
    started = time.time()
    try:
        if args.prepare_only:
            print(f"Prepared: {project}")
            return
        if not (args.pds_home / "arch/vendor/pango/logos2/pg2l100h").is_dir():
            raise RuntimeError(f"{args.pds_home} lacks PG2L100H device data; portable project is prepared at {project}")
        shell = args.pds_home / "bin/pds_shell.exe"
        log = destination / "bitstream_console.log"
        with log.open("w", encoding="utf-8") as output:
            result = subprocess.run([str(shell), "-project", str(project), "-run", "gen_bit_stream"], cwd=destination,
                                    stdout=output, stderr=subprocess.STDOUT)
        manifest["artifacts"][project.name] = digest(project)
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        text = log.read_text(encoding="utf-8", errors="replace")
        if result.returncode or re.search(r"(?m)^E:", text):
            raise RuntimeError(f"PDS build failed: {log}")
        bitstream = destination / f"generate_bitstream/{TOP}.sbit"
        timing = destination / f"place_route/{TOP}_timing_summary_after_hold_fix.txt"
        if not bitstream.is_file() or bitstream.stat().st_mtime < started:
            raise RuntimeError("PDS did not generate a fresh bitstream")
        if not timing.is_file() or "Design Summary : All Constraints Met." not in timing.read_text(errors="replace"):
            raise RuntimeError("Inspect timing reports before programming the board")
        detailed_timing = destination / f"report_timing/{TOP}.rtr"
        if not detailed_timing.is_file() or detailed_timing.stat().st_mtime < started:
            raise RuntimeError("PDS did not generate a fresh detailed timing report")
        if re.search(r"Slack\s+\(VIOLATED\)", detailed_timing.read_text(errors="replace")):
            raise RuntimeError("Detailed timing report still contains a violated path")
        report.update(success=True, timing_constraints_met=True, bitstream_sha256=digest(bitstream), bitstream_bytes=bitstream.stat().st_size)
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        report["completed_utc"] = datetime.now(timezone.utc).isoformat()
        (destination / "build_summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
