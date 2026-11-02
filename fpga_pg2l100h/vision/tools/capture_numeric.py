import argparse
import binascii
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import sys
import time


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "model"))
from gesture_standard import HAND_NAMES, POSES, STANDARD_ID, definition


def parse_frame(lines):
    content = [line.strip() for line in lines if line.strip()]
    if len(content) != 66 or content[0] != "Q7FRAME BEGIN" or not re.fullmatch(r"Q7FRAME END [0-9A-Fa-f]{8}", content[-1]):
        raise ValueError("Incomplete Q7 frame: expected BEGIN, 64 rows and CRC32 END")
    if any(not re.fullmatch(r"[0-9A-Fa-f]{128}", row) for row in content[1:-1]):
        raise ValueError("Q7 row must contain exactly 64 hex bytes")
    data = bytes.fromhex("".join(content[1:-1]))
    if max(data) > 127 or any(data[:128]) or any(data[-128:]):
        raise ValueError("Invalid Q7 range or camera padding rows")
    if binascii.crc32(data) != int(content[-1].split()[-1], 16):
        raise ValueError("Serial frame CRC32 mismatch")
    return data


def read_frame(connection, timeout):
    connection.reset_input_buffer()
    connection.write(b"d")
    lines = []
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        line = connection.readline().decode("ascii", errors="replace").strip()
        if line == "Q7FRAME BEGIN":
            lines = [line]
        elif lines and line:
            lines.append(line)
            if line.startswith("Q7FRAME END"):
                return parse_frame(lines)
    raise TimeoutError("No complete FPGA frame; enable inference and camera, exit bars/freeze, then retry")


def save_frame(data, output, session, card_id, split, label, box, mode="label"):
    from PIL import Image
    if mode not in ["label", "hand"] or (label is not None and label not in range(1 if mode == "hand" else 0, 11 if mode == "hand" else 10)):
        raise ValueError("Label mode supports 0-9; northern hand captures support 1-10")
    classes = HAND_NAMES if mode == "hand" else [f"digit {digit}" for digit in range(10)]
    class_file = output / "classes.json"
    if class_file.exists() and json.loads(class_file.read_text()) != classes:
        raise ValueError("Keep label and hand captures in separate dataset directories")
    standard_file = output / "gesture_standard.json"
    if mode == "hand" and class_file.exists() and (not standard_file.exists() or json.loads(standard_file.read_text(encoding="utf-8")) != definition()):
        raise ValueError("Use a new directory for northern-reference gesture captures")
    for value in [session, card_id]:
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", value):
            raise ValueError("Session and card ID must use 1-64 ASCII letters, numbers, hyphens or underscores")
    digest = hashlib.sha256(data).hexdigest()
    for sidecar in output.glob("metadata/*/*.json"):
        metadata = json.loads(sidecar.read_text(encoding="utf-8"))
        if metadata["split"] != split and (metadata["session"] == session or metadata["card_id"] == card_id or metadata["sha256"] == digest):
            raise ValueError("Session, physical card or identical frame already belongs to another split")
    if label is not None and box is not None:
        left, top, right, bottom = box
        if not (0 <= left < right <= 64 and 2 <= top < bottom <= 62):
            raise ValueError("Box coordinates must lie inside the 64x64 model input, excluding padded rows")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%f")
    name = f"{session}_{card_id}_{stamp}_{digest[:8]}"
    for category in ["images", "labels", "metadata", "q7"]:
        (output / category / split).mkdir(parents=True, exist_ok=True)
    grayscale = Image.frombytes("L", (64, 64), bytes(255 - 2 * value for value in data))
    canvas = Image.new("RGB", (160, 120), "white")
    canvas.paste(grayscale.crop((0, 2, 64, 62)).resize((128, 120), Image.Resampling.NEAREST).convert("RGB"), (16, 0))
    canvas.save(output / "images" / split / (name + ".png"))
    (output / "q7" / split / (name + ".bin")).write_bytes(data)
    if label is None:
        (output / "labels" / split / (name + ".txt")).write_text("", encoding="ascii")
    elif box is not None:
        left, top, right, bottom = box
        center_x = (16 + left + right) / 160
        center_y = (top + bottom - 4) / 120
        width = (right - left) * 2 / 160
        height = (bottom - top) * 2 / 120
        class_index = label - 1 if mode == "hand" else label
        (output / "labels" / split / (name + ".txt")).write_text(f"{class_index} {center_x:.8f} {center_y:.8f} {width:.8f} {height:.8f}\n", encoding="ascii")
    metadata = dict(session=session, card_id=card_id, split=split, mode=mode, label=label, box=box, sha256=digest, crc32=f"{binascii.crc32(data):08x}", captured_utc=datetime.now(timezone.utc).isoformat(), origin="FPGA UART model-input snapshot; image is reconstructed grayscale, not raw RGB", input_file=f"q7/{split}/{name}.bin")
    if mode == "hand":
        metadata.update(gesture_standard=STANDARD_ID, pose=POSES[label - 1] if label is not None else "negative/background")
        standard_file.write_text(json.dumps(definition(), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (output / "metadata" / split / (name + ".json")).write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    class_file.write_text(json.dumps(classes, indent=2) + "\n", encoding="utf-8")
    return name


def main():
    parser = argparse.ArgumentParser(description="Capture an exact FPGA input with CRC32; keep physical cards and sessions disjoint across dataset splits")
    parser.add_argument("--port", required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--card-id", required=True)
    parser.add_argument("--split", choices=["train", "val", "test"], default="test")
    parser.add_argument("--label", choices=[str(digit) for digit in range(11)] + ["none"], required=True)
    parser.add_argument("--box", type=int, nargs=4, metavar=("LEFT", "TOP", "RIGHT", "BOTTOM"))
    parser.add_argument("--mode", choices=["label", "hand"], default="label")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--count", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=10)
    args = parser.parse_args()
    if args.count < 1:
        parser.error("--count must be positive")
    import serial
    label = None if args.label == "none" else int(args.label)
    if (args.mode == "hand" and label == 0) or (args.mode == "label" and label == 10):
        parser.error("Label mode supports 0-9; northern hand captures support 1-10")
    output = args.output or ROOT / "model/checkpoints" / ("camera_hand_northern10" if args.mode == "hand" else "camera_numeric")
    with serial.Serial(args.port, 115200, timeout=0.3) as connection:
        connection.write(b"g" if args.mode == "hand" else b"l")
        expected_modes = {"MODE HAND 1-9", "MODE HAND 1-10"} if args.mode == "hand" else {"MODE HANDWRITE 0-9", "MODE LABEL 0-9"}
        deadline = time.monotonic() + args.timeout
        while connection.readline().decode("ascii", errors="replace").strip() not in expected_modes:
            if time.monotonic() >= deadline:
                raise TimeoutError("FPGA did not acknowledge the requested model mode")
        for _ in range(args.count):
            data = read_frame(connection, args.timeout)
            print(save_frame(data, output, args.session, args.card_id, args.split, label, args.box, args.mode), flush=True)
    if label is not None and args.box is None:
        print("Classification-only capture: add a measured --box before using this sample for detector training.")


if __name__ == "__main__":
    main()
