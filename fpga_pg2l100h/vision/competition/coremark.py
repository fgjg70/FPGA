import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import urllib.request
import zipfile


ROOT = Path(__file__).resolve().parents[1]
REVISION = "1f483d5b8316753a742cbf5590caf5bd0a4e4777"
ARCHIVE_SHA256 = "acc21470160d85e078c015f9bb1878166bfe9bf2971d8de37455556b098f4676"
FILES = {
    "core_main.c": "17884c93c5b94378eb0ff02b4df3725756cf2addb9b8cbcaa6200a4649ff5ca7",
    "core_list_join.c": "ca00e4e010ece47d7f040cb92aa50a95345a00d3171b59d088f6b243be06ce7b",
    "core_matrix.c": "ecdff717b5a5c4907d221a606760e25499899cbf617582c05d40db71c91351e4",
    "core_state.c": "f4b84bb0a3452c45a4daa664ab502bfdccbd31cb57d93e9ac490c60937717a4e",
    "core_util.c": "a3fbfcb9bb943b638624b8ece01c5836dd56a96d7bcde2697b248d077447327f",
    "coremark.h": "42642b9a06c7ed2b3bd9eda971b7c3868c4f5d27bf7ef6c4bba11291a0c2598a",
    "LICENSE.md": "9577b9c846f61fd69a0d8ac965998c6450c7d8969f71f0bb4a931b91aebad28a",
}


def sources():
    destination = ROOT / "build/coremark_source"
    if not all((destination / name).is_file() for name in FILES):
        request = urllib.request.Request(f"https://codeload.github.com/eembc/coremark/zip/{REVISION}", headers={"User-Agent": "NUMGUARD-FPGA"})
        data = urllib.request.urlopen(request, timeout=45).read()
        if hashlib.sha256(data).hexdigest() != ARCHIVE_SHA256:
            raise ValueError("CoreMark archive checksum mismatch")
        archive = zipfile.ZipFile(io.BytesIO(data))
        destination.mkdir(parents=True, exist_ok=True)
        for name in FILES:
            (destination / name).write_bytes(archive.read(f"coremark-{REVISION}/{name}"))
    for name, expected in FILES.items():
        if hashlib.sha256((destination / name).read_bytes()).hexdigest() != expected:
            raise ValueError(f"CoreMark source changed: {name}; official benchmark algorithms must remain unchanged")
    return destination


def compile_objects(destination, gcc, common, iterations):
    source_dir = sources()
    flags = common + ["-I", str(source_dir), "-I", str(ROOT / "competition"), f"-DITERATIONS={iterations}", "-DPERFORMANCE_RUN=1", "-DVALIDATION_RUN=0", "-DPROFILE_RUN=0", "-DTOTAL_DATA_SIZE=2000"]
    objects = []
    for source in [ROOT / "firmware/start.S", *[source_dir / name for name in FILES if name.endswith(".c")], ROOT / "competition/core_portme.c"]:
        output = destination / (source.stem + ".o")
        subprocess.run(flags + ["-Wno-unused-parameter", "-Wno-sign-compare", "-c", str(source), "-o", str(output)], check=True)
        objects.append(str(output))
    clocks = json.loads((ROOT / "clock_config.json").read_text())
    (destination / "benchmark.json").write_text(json.dumps(dict(source="EEMBC/CoreMark", revision=REVISION, source_sha256=FILES, iterations=iterations, clock_hz=clocks["system_clock_hz"], cpu_clock_hz=clocks["cpu_clock_hz"], minimum_measured_seconds=10, measured=False, compiler_flags=flags[1:]), indent=2) + "\n", encoding="utf-8")
    return objects


def parse_log(text, lut_count=None):
    matches = re.findall(r"CM64 ticks=([0-9a-fA-F]{16}) clock=(\d+) iterations=(\d+)(?: cpu=(\d+))?", text)
    if len(matches) != 1:
        raise ValueError("Expected exactly one complete CoreMark measurement")
    raw_ticks, raw_clock, raw_iterations, raw_cpu_clock = matches[0]
    ticks, clock, iterations = int(raw_ticks, 16), int(raw_clock), int(raw_iterations)
    cpu_clock = int(raw_cpu_clock) if raw_cpu_clock else clock
    reference = dict(seedcrc=0xe9f5, crclist=0xe714, crcmatrix=0x1fd7, crcstate=0x8e3a)
    valid_crc = all((match := re.search(r"\b" + name + r"\s*:\s*0x([0-9a-fA-F]+)", text)) is not None and int(match[1], 16) == value for name, value in reference.items())
    overall_validated = "Correct operation validated." in text
    errors = re.search(r"ERROR!|Errors detected|Cannot validate|ERROR! Must execute", text) is not None
    seconds = ticks / clock if clock else 0
    clocks = json.loads((ROOT / "clock_config.json").read_text())
    cpu_frequency_valid = cpu_clock == clocks["cpu_clock_hz"] if raw_cpu_clock else cpu_clock == clock
    eligible = valid_crc and overall_validated and not errors and seconds >= 10 and iterations > 0 and clock == clocks["system_clock_hz"] and cpu_frequency_valid
    result = dict(eligible=eligible, crc_validated=valid_crc, overall_validated=overall_validated, errors_in_log=errors, ticks=ticks, clock_hz=clock, cpu_clock_hz=cpu_clock, cpu_frequency_declared=bool(raw_cpu_clock), iterations=iterations, seconds=seconds)
    if eligible:
        result.update(coremark=iterations / seconds, coremark_per_mhz=iterations / seconds / (cpu_clock / 1000000))
        if lut_count:
            result["lut_count"] = lut_count
            result["coremark_per_lut"] = result["coremark"] / lut_count
    return result


def main():
    parser = argparse.ArgumentParser(description="Validate genuine 64-bit CoreMark UART measurements; rejects short or bad-CRC runs")
    parser.add_argument("--log", type=Path)
    parser.add_argument("--luts", type=int)
    parser.add_argument("--output", type=Path, default=ROOT / "validation/coremark_result.json")
    args = parser.parse_args()
    if args.luts is not None and args.luts <= 0:
        parser.error("--luts must be positive and taken from the corresponding PDS report")
    if not args.log:
        print(sources())
        return
    report = parse_log(args.log.read_text(encoding="utf-8", errors="replace"), args.luts)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    if not report["eligible"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
