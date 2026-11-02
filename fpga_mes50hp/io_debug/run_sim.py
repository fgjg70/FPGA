import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description="Simulate MES50HP HDMI, UART and six keys")
    parser.add_argument("--iverilog", type=Path)
    args = parser.parse_args()
    cached = Path(tempfile.gettempdir()) / "codex-fpga-sim/mingw64/bin/iverilog.exe"
    compiler = Path(args.iverilog or os.environ.get("IVERILOG") or shutil.which("iverilog") or cached).resolve()
    if not compiler.is_file():
        parser.error("Install Icarus Verilog, or specify --iverilog /path/to/iverilog")
    runtime = compiler.with_name("vvp" + compiler.suffix)
    destination = ROOT / "sim"
    destination.mkdir(exist_ok=True)
    sources = sorted((ROOT / "rtl").glob("*.v")) + sorted((ROOT / "tb").glob("*.sv"))
    compiler_options = [str(compiler), "-g2012", "-Wall"]
    library = compiler.parent.parent / "lib/ivl"
    if library.is_dir():
        compiler_options += ["-B", str(library)]
    environment = os.environ.copy()
    environment["PATH"] = str(compiler.parent) + os.pathsep + environment.get("PATH", "")
    started = time.time()
    report = {"passed": False, "hardware_programmed": False,
              "input_sha256": {path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                               for path in sources}}
    result_file = destination / "result.json"
    result_file.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    log = destination / "simulation.log"
    print(f"Simulation log: {log}", flush=True)
    with log.open("w", encoding="utf-8") as output:
        for top in ["tb_console", "tb_clock_health", "tb_io_debug"]:
            executable = destination / (top + ".vvp")
            command = compiler_options + ["-s", top, "-o", str(executable)] + [str(path) for path in sources]
            subprocess.run(command, cwd=destination, env=environment, check=True, stdout=output, stderr=subprocess.STDOUT)
            subprocess.run([str(runtime), "-i", str(executable)], cwd=destination, env=environment, check=True,
                           stdout=output, stderr=subprocess.STDOUT, timeout=600)
    text = log.read_text(encoding="utf-8")
    if not all(marker in text for marker in ["IO_DEBUG_PASS", "CONSOLE_PASS", "CLOCK_HEALTH_PASS"]):
        raise RuntimeError("Simulation did not report all PASS markers")
    uart = (destination / "uart_capture.bin").read_bytes()
    if b"UART_LOOPBACK_OK\r\n" not in uart or b"HDMI=OK" not in uart or b"FRAME=1" not in uart:
        raise AssertionError("Decoded UART output is missing echo, HDMI success or framing diagnostics")
    if b"VIDEO=STOP" not in uart or b"VIDEO=OK" not in uart:
        raise AssertionError("Decoded UART output is missing pixel clock health diagnostics")
    ppm = (destination / "display.ppm").read_bytes()
    header = b"P6\n720 576\n255\n"
    if not ppm.startswith(header) or len(ppm) != len(header) + 720 * 576 * 3:
        raise AssertionError("Captured display is not exactly 720x576 RGB888")
    pixels = ppm[len(header):]
    bars = [bytes(color) for color in [(255,255,255), (255,255,0), (0,255,255), (0,255,0),
                                      (255,0,255), (255,0,0), (0,0,255), (0,0,0)]]
    for index, expected in enumerate(bars):
        offset = (80 * 720 + 45 + index * 90) * 3
        if pixels[offset:offset+3] != expected:
            raise AssertionError(f"Color bar {index} does not match expected RGB order")
    try:
        from PIL import Image
    except ImportError:
        pass
    else:
        with Image.open(destination / "display.ppm") as image:
            image.save(destination / "display.png")
    report.update({"passed": True, "elapsed_seconds": round(time.time() - started, 2),
                   "checks": [line for line in text.splitlines() if line.startswith("PASS ")],
                   "decoded_uart_bytes": len(uart), "display_size": [720, 576]})
    result_file.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(text.strip())
    print(json.dumps({key: value for key, value in report.items() if key != "input_sha256"}, indent=2))


if __name__ == "__main__":
    main()
