import csv
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import re
import statistics
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]


def read(relative):
    return (ROOT / relative).read_text(encoding="utf-8", errors="replace")


def digest(relative):
    return hashlib.sha256((ROOT / relative).read_bytes()).hexdigest()


def simulation_passed(relative, evidence=None):
    path = ROOT / relative
    if not path.is_file():
        return False
    content = read(relative)
    return "RESULT : PASS" in content and not re.search(r"(?mi)^fatal:", content) and (evidence is None or evidence in content)


def timing_paths(timing, label):
    section = timing.split(label + " Summary(Slow Corner):", 1)[1].split("====================================================================================================", 1)[0]
    matches = re.findall(r"(?m)^\s*(sys_clk_core|video_clk)\s+(sys_clk_core|video_clk|hdmi_pixel)\s+(-?[\d.]+)\s+", section)
    result = {launch + " -> " + capture: float(slack) for launch, capture, slack in matches}
    if len(result) != 3 or min(result.values()) < 0:
        raise RuntimeError("Missing or failing " + label + " timing paths")
    return result


def main():
    subprocess.run([sys.executable, str(ROOT / "prepare_rtl.py"), "--check", "--app", "digit"], cwd=ROOT, check=True)
    build = ROOT / "build/digit"
    build_report = json.loads((build / "build_summary.json").read_text(encoding="utf-8"))
    manifest = json.loads(read("generated/manifest.json"))
    if manifest.get("app") != "digit":
        raise RuntimeError("Current generated configuration is not digit")
    current_manifest = digest("generated/manifest.json")
    if current_manifest != build_report["manifest_sha256"]:
        raise RuntimeError("Application bitstream and current generated manifest differ")
    if digest("generated/profile_constraints.fdc") != digest("mes50hp_digit.fdc"):
        raise RuntimeError("Current constraints differ from the application pin/timing constraints")
    synthesis = read("build/digit/synthesize/top_mes50hp.snr")
    timing = read("build/digit/report_timing/top_mes50hp.rtr")
    setup = timing_paths(timing, "Setup")
    hold = timing_paths(timing, "Hold")
    resources = {}
    for name, pattern in {
        "luts": r"Total LUTs:\s*(\d+)",
        "registers": r"Total Registers:\s*(\d+)",
        "drm18k_equivalent": r"Total DRM18K\s*=\s*([\d.]+)",
        "apms": r"Total APMs\s*=\s*([\d.]+)",
    }.items():
        match = re.search(pattern, synthesis)
        if not match:
            raise RuntimeError("Missing resource: " + name)
        resources[name] = float(match.group(1))
    candidates = ["validation/digit_sim", "validation/digit_verilator", "validation/digit_xsim"]
    full_simulation = next((directory for directory in candidates if simulation_passed(directory + "/digit.log", "torn-write")), None)
    if full_simulation is None:
        raise RuntimeError("A full digit application simulation has not passed")
    full_report = json.loads(read(full_simulation + "/result.json"))
    for source, checksum in full_report.get("inputs_sha256", {}).items():
        if digest(source) != checksum:
            raise RuntimeError("Application simulation is stale: " + source)
    with (ROOT / full_simulation / "measurements.csv").open(newline="", encoding="utf-8") as source:
        rows = [{name: int(value) for name, value in row.items()} for row in csv.DictReader(source)]
    comparisons = [row for row in rows if row["software_cycles"] and row["hardware_cycles"]]
    python_log = read("validation/digit_python.log")
    python_count = re.search(r"Ran (\d+) tests", python_log)
    checks = {
        "gemm_abort_restart": simulation_passed("validation/gemm_sim/gemm.log", "abort/restart"),
        "boot_and_echo": simulation_passed("validation/sim/boot.log"),
        "uart_fifo_errors": simulation_passed("validation/uart_fifo_sim/uart.log"),
        "keys_video_atomic_frame": simulation_passed("validation/peripheral_sim/peripherals.log", "720x576"),
        "digit_application_eeprom_hdmi": simulation_passed(full_simulation + "/digit.log", "torn-write"),
        "digit_uart_115200": simulation_passed("validation/digit_uart_smoke/digit.log", "115200"),
        "missing_peripherals": simulation_passed("validation/digit_missing_sim/digit.log", "save error visible"),
        "python_model_protocol_gui": bool(python_count and int(python_count.group(1)) >= 21 and re.search(r"(?m)^OK\s*$", python_log)),
    }
    if not all(checks.values()) or len(rows) != 10 or not comparisons or {row["digit"] for row in rows} != set(range(10)):
        raise RuntimeError("Required application validation is incomplete: " + repr(checks))
    if "All Constraints Met" not in timing:
        raise RuntimeError("Application timing did not pass")
    if digest(build_report["bitstream"]) != build_report["bitstream_sha256"]:
        raise RuntimeError("Application bitstream hash changed")
    model = json.loads(read("model/metrics.json"))
    if model["preprocessing_version"] != "digit-normalize-v2":
        raise RuntimeError("Model preprocessing version differs")
    report = {
        "date": datetime.now(timezone(timedelta(hours=8))).date().isoformat(),
        "app": "digit", "protocol_version": 2, "device": build_report["device"],
        "clock_hz": 50000000, "hardware_programmed": False, "physical_hdmi_verified": False,
        "physical_eeprom_power_cycle_verified": False, "physical_uart_accuracy_measured": False,
        "model_test_source": "PC integer reference on 10000 MNIST test images using the same preprocessing as GUI/CLI/evaluation",
        "preprocessing_version": model["preprocessing_version"],
        "model_test_accuracy": model["int8_test_accuracy"], "model_sha256": model["model_sha256"],
        "resources": resources, "setup_wns_ns": setup["sys_clk_core -> sys_clk_core"],
        "setup_paths_ns": setup, "hold_paths_ns": hold, "timing_constraints_met": True,
        "external_interfaces": "HDMI RGB/HS/VS/DE constrained to inverted 27 MHz output pixel clock (max 5 ns/min 1 ns delay); asynchronous UART/keys/LEDs/open-drain I2C are false paths",
        "video": {"width": 720, "height": 576, "frames_per_second": 50, "pixel_clock_hz": 27000000,
                  "total_width": 864, "total_height": 625, "frame_snapshot": "validation/peripheral_sim/display.png",
                  "frame_png_sha256": digest("validation/peripheral_sim/display.png")},
        "eeprom": {"device": "24LC02", "address_7bit": 80, "page_bytes": 8, "record_bytes": 24,
                   "slot_offsets": [0, 32], "crc": "CRC16/CCITT-FALSE", "commit_marker": 165,
                   "default_pin": "1234", "default_mode": "hardware", "default_unlock_ms": 5000,
                   "reset_behavior": "reload newest valid EEPROM record, clear image/candidate/progress, lock door"},
        "checks": checks, "python_tests": int(python_count.group(1)),
        "full_simulation_report": full_report,
        "simulated_digits": 10, "simulated_logits_checked": 100,
        "measurements_source": full_simulation + "/measurements.csv; RTL simulation of RV32IM firmware; full test UART 1 Mbaud, separate smoke at 115200 baud",
        "measurements_scope": "Inference only, including CPU transfer/scheduling/key service; excludes UART transport, PC preprocessing, display refresh and EEPROM writes",
        "measurements": rows,
        "median_software_to_hardware_speedup": statistics.median(row["software_cycles"] / row["hardware_cycles"] for row in comparisons),
        "serial_inference_min_roundtrip_ms": {"full_64_byte_result": (264 + 72) * 10 * 1000 / 115200,
                                              "compact_24_byte_result": (264 + 32) * 10 * 1000 / 115200},
        "bitstream": build_report["bitstream"], "bitstream_sha256": build_report["bitstream_sha256"],
        "generated_manifest_sha256": current_manifest,
    }
    output = ROOT / "validation/digit_summary.json"
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
