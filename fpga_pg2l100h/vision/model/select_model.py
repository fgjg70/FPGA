import argparse
import hashlib
import json
from pathlib import Path
import shutil


ROOT = Path(__file__).resolve().parent
MODEL_FILES = ["micro_yolo.npz", "weights.hex", "biases.hex", "shifts.hex", "model.json"]


def main():
    parser = argparse.ArgumentParser(description="Select a trained and verified-format model for the next FPGA build")
    parser.add_argument("--source", type=Path, required=True)
    args = parser.parse_args()
    source = args.source.resolve()
    metadata = json.loads((source / "model.json").read_text(encoding="utf-8"))
    expected_layers = [[1, 8, 3, 2], [8, 16, 3, 2], [16, 24, 3, 2], [24, 32, 3, 2], [32, 32, 3, 1], [32, 27, 1, 1]]
    expected_classes = ["people", "bike", "cup"] + [f"hand {number}" for number in range(1, 10)] + [f"digit {number}" for number in range(10)]
    if metadata["input"] != [64, 64, 1] or metadata["architecture"] != expected_layers or metadata["classes"] != expected_classes:
        raise ValueError("Model architecture does not match the FPGA accelerator")
    enabled = metadata["enabled_classes"]
    if not enabled or len(set(enabled)) != len(enabled) or any(not 0 <= category < 22 for category in enabled):
        raise ValueError("Invalid trained class mask")
    if set(metadata["sha256"]) != set(MODEL_FILES) - {"model.json"}:
        raise ValueError("Model digest manifest must cover every weight and bias file")
    for name, expected in metadata["sha256"].items():
        if name not in MODEL_FILES or hashlib.sha256((source / name).read_bytes()).hexdigest() != expected:
            raise ValueError(f"Model digest mismatch: {name}")
    vectors = [f"{kind}_{index}.hex" for index in range(8) for kind in ["input", "output"]] + ["reference_detections.json"]
    for name in MODEL_FILES:
        if not (source / name).is_file():
            raise ValueError(f"Missing model file: {name}")
    for name in vectors:
        if not (source / "vectors" / name).is_file():
            raise ValueError(f"Missing reference vector: {name}")
    if source == ROOT:
        raise ValueError("Source is already the active model directory")
    for name in MODEL_FILES:
        shutil.copy2(source / name, ROOT / name)
    (ROOT / "vectors").mkdir(exist_ok=True)
    for name in vectors:
        shutil.copy2(source / "vectors" / name, ROOT / "vectors" / name)
    print("Selected classes: " + ", ".join(metadata["classes"][category] for category in enabled))
    print("Regenerate the PDS project and rerun verification before building a bitstream.")


if __name__ == "__main__":
    main()
