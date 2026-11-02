import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


PROJECT_DIR = Path(__file__).resolve().parent
GENERATED_DIR = PROJECT_DIR / "generated"
RTL_PATH = GENERATED_DIR / "riscv_pds.v"
MANIFEST_PATH = GENERATED_DIR / "manifest.json"


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_paths():
    filenames = (PROJECT_DIR / "sources.f").read_text(encoding="utf-8").splitlines()
    paths = [PROJECT_DIR / filename.strip() for filename in filenames if filename.strip()]
    for path in paths:
        if not path.is_file():
            raise FileNotFoundError(f"Missing source: {path}")
    return paths


def main():
    parser = argparse.ArgumentParser(description="Generate PDS-compatible Verilog from src/.")
    parser.add_argument("--sv2v", default=os.environ.get("SV2V"))
    parser.add_argument("--check", action="store_true", help="Check generated RTL freshness.")
    args = parser.parse_args()
    paths = source_paths()
    source_hashes = {path.relative_to(PROJECT_DIR).as_posix(): sha256(path) for path in paths}

    if args.check:
        manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
        if manifest["sources"] != source_hashes or manifest["rtl_sha256"] != sha256(RTL_PATH):
            raise RuntimeError("Generated RTL is stale. Run create_project.bat.")
        print(f"PASS: generated RTL matches all {len(paths)} source files.")
        return

    converter = args.sv2v or PROJECT_DIR / "tools" / "sv2v" / "sv2v.exe"
    converter_path = shutil.which(str(converter))
    if not converter_path:
        raise FileNotFoundError("sv2v not found. Set SV2V or run setup_tools.ps1.")
    version = subprocess.check_output([converter_path, "--numeric-version"], text=True).strip()
    GENERATED_DIR.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="convert-", dir=GENERATED_DIR) as temporary_dir:
        temporary_rtl = Path(temporary_dir) / "riscv_pds.v"
        subprocess.run(
            [converter_path, "-D", "SYNTHESIS", f"--write={temporary_rtl}", *map(str, paths)],
            cwd=PROJECT_DIR,
            check=True,
        )
        converted_text = temporary_rtl.read_text(encoding="utf-8")
        temporary_rtl.write_text("`timescale 1ns/1ps\n" + converted_text, encoding="utf-8")
        temporary_rtl.replace(RTL_PATH)
    manifest = {
        "converter": f"sv2v {version}",
        "converter_sha256": sha256(Path(converter_path)),
        "defines": ["SYNTHESIS"],
        "sources": source_hashes,
        "rtl_sha256": sha256(RTL_PATH),
    }
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Generated {RTL_PATH.relative_to(PROJECT_DIR)} from {len(paths)} sources using sv2v {version}.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
