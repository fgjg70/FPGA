import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import sys
import time


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from build import build_firmware, digest, find_gcc
sys.path.insert(0, str(ROOT))
from verify import run_icarus
from coremark import parse_log


def main():
    parser = argparse.ArgumentParser(description="Run one unmodified official CoreMark iteration on the actual RTL CPU; never publish this short simulation as a score")
    parser.add_argument("--iverilog", type=Path, default=Path.home() / "AppData/Local/Temp/codex-fpga-sim/mingw64/bin/iverilog.exe")
    args = parser.parse_args()
    source = ROOT / "build/coremark_j11"
    stage = ROOT / "build/coremark_sim"
    stage.mkdir(parents=True, exist_ok=True)
    for name in ["rtl", "model", "firmware"]:
        shutil.copytree(source / name, stage / name, dirs_exist_ok=True)
    model = json.loads((ROOT / "model/model.json").read_text())
    sizes = build_firmware(stage, find_gcc(), model, "coremark", 1)
    destination = ROOT / "validation"
    started = time.time()
    messages = run_icarus("coremark", stage, destination, args.iverilog.resolve())
    log = (destination / "coremark.log").read_text(errors="replace")
    measurement = parse_log(log)
    required = ["seedcrc          : 0xe9f5", "crclist       : 0xe714", "crcmatrix     : 0x1fd7", "crcstate      : 0x8e3a"]
    if not all(text in log for text in required) or "ERROR! list crc" in log or "ERROR! matrix crc" in log or "ERROR! state crc" in log:
        raise AssertionError("Official 2K performance CRCs did not match; inspect coremark.log")
    if measurement["eligible"]:
        raise AssertionError("One-iteration simulation unexpectedly passed the >=10-second score gate")
    report = dict(functional_success=True, eligible_score=False, hardware_tested=False, crc_checked=True,
                  simulation_uart_baud=6250000, deployment_uart_baud=115200,
                  measurement=measurement, elapsed_seconds=round(time.time() - started, 2),
                  rtl_sha256={path.name: digest(path) for path in (stage / "rtl").glob("*.v")},
                  completed_utc=datetime.now(timezone.utc).isoformat(), **sizes)
    (destination / "coremark_functional.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("\n".join(messages))
    print("PASS official CoreMark reference CRCs; >=10-second hardware benchmark remains required")


if __name__ == "__main__":
    main()
