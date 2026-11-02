import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "model"))
from gesture_standard import HAND_INDICES


def main():
    compiler = os.environ.get("HOST_GCC") or shutil.which("gcc")
    if not compiler:
        raise FileNotFoundError("Native GCC is required for the actual firmware decoder test")
    source = ROOT / "firmware/numeric_main.c"
    text = source.read_text(encoding="utf-8")
    register_macro = "#define REG(offset) (*(volatile uint32_t *)(0xa1000000u + (offset)))"
    if text.count(register_macro) != 1:
        raise ValueError("The test MMIO substitution no longer matches the actual firmware")
    messages = []
    with tempfile.TemporaryDirectory(dir=ROOT / "validation", prefix="hand_firmware_test_") as directory:
        temporary = Path(directory)
        (temporary / "numeric_main_fixture.c").write_text(text.replace(register_macro, ""), encoding="utf-8")
        shutil.copy2(ROOT / "firmware/numeric_guard.h", temporary / "numeric_guard.h")
        (temporary / "platform_clock.h").write_text("#define CLOCK_HZ 50000000u\n", encoding="ascii")
        for count in [9, 10]:
            header = "#define MODEL_CLASS_MASK 0x003ff000u\n"
            for prefix in ["MODEL", "GESTURE"]:
                header += f"#define {prefix}_OBJECT_THRESHOLD 72\n#define {prefix}_CLASS_MARGIN 24\n#define {prefix}_EMPTY_SCORE 40\n"
            header += f"#define GESTURE_DIGIT_MAX {count}\n"
            header += "static const unsigned char gesture_class_indices[GESTURE_DIGIT_MAX] = {" + ", ".join(map(str, HAND_INDICES[:count])) + "};\n"
            (temporary / "model_info.h").write_text(header, encoding="ascii")
            output = temporary / f"hand_{count}.exe"
            subprocess.run([compiler, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-I", str(temporary), str(ROOT / "sim/test_hand_firmware.c"), "-o", str(output)], check=True, timeout=30)
            result = subprocess.run([str(output)], check=True, capture_output=True, text=True, timeout=10)
            messages += result.stdout.splitlines()
    report = dict(success=True, test_type="Actual production firmware with host MMIO fixture, nine- and ten-class model headers; not trained-model or board recognition validation",
                  firmware_sha256=hashlib.sha256(source.read_bytes()).hexdigest(), checks=messages)
    (ROOT / "validation/hand_firmware_summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("\n".join(messages))


if __name__ == "__main__":
    main()
