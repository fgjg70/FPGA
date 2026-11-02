import argparse
import json
from pathlib import Path
import sys

import numpy as np
import torch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "model"))
from network import integer_forward
from gesture_standard import HAND_INDICES, HAND_NAMES, STANDARD_ID, require_standard


def prediction_for_output(output, model, mode):
    indices = HAND_INDICES[:len(model["enabled_classes"])] if mode == "hand" else list(range(12, 22))
    cells = output.reshape(16, 27)
    cell = cells[int(np.argmax(cells[:, 0]))]
    class_scores = [int(cell[5 + category]) for category in indices]
    scores = sorted(class_scores, reverse=True)
    margin = scores[0] - scores[1]
    accepted = int(cell[0]) >= model["object_threshold"] and margin >= model.get("class_margin_threshold", 24)
    predicted = int(np.argmax(class_scores)) + (1 if mode == "hand" else 0) if accepted else None
    return predicted, int(cell[0]), margin


def main():
    parser = argparse.ArgumentParser(description="Evaluate exact captured FPGA inputs against human supplied ground truth, including rejects and negative false positives")
    parser.add_argument("--mode", choices=["label", "hand"], default="label")
    parser.add_argument("--dataset", type=Path)
    parser.add_argument("--model", type=Path)
    parser.add_argument("--split", choices=["val", "test"], default="test")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/real_camera_report.json")
    args = parser.parse_args()
    model_dir = args.model or (ROOT / "model/gesture" if args.mode == "hand" else ROOT / "model")
    model = json.loads((model_dir / "model.json").read_text(encoding="utf-8"))
    args.dataset = args.dataset or ROOT / "model/checkpoints" / ("camera_hand_northern10" if args.mode == "hand" else "camera_numeric")
    count = len(model["enabled_classes"])
    enabled = HAND_INDICES[:count] if args.mode == "hand" else list(range(12, 22))
    names = HAND_NAMES[:count] if args.mode == "hand" else [f"digit {number}" for number in range(10)]
    if (args.mode == "hand" and count not in [9, 10]) or model["enabled_classes"] != sorted(enabled):
        raise ValueError("Model classes do not match the requested input mode")
    if json.loads((args.dataset / "classes.json").read_text(encoding="utf-8")) != names or any(model["classes"][index] != name for index, name in zip(enabled, names)):
        raise ValueError("Dataset and model gesture sets differ; the legacy nine-class bank cannot evaluate the northern ten-class set")
    if args.mode == "hand" and count == 10:
        require_standard(args.dataset)
        if model.get("gesture_standard") != STANDARD_ID:
            raise ValueError("Model uses another gesture convention")
    torch.set_num_threads(4)
    records = sorted((args.dataset / "metadata" / args.split).glob("*.json"))
    if not records:
        raise ValueError("No captures exist; real-camera accuracy cannot be reported before collecting data")
    with np.load(model_dir / "micro_yolo.npz", allow_pickle=False) as archive:
        arrays = dict(archive)
    digits = list(range(1, count + 1)) if args.mode == "hand" else list(range(10))
    digit_indices = {digit: index for index, digit in enumerate(digits)}
    unknown = len(digits)
    confusion = np.zeros((unknown + 1, unknown + 1), dtype=np.int64)
    predictions = []
    for path in records:
        metadata = json.loads(path.read_text(encoding="utf-8"))
        if metadata.get("mode", "label") != args.mode:
            raise ValueError("Captured input mode does not match the model")
        if args.mode == "hand" and count == 10 and metadata.get("gesture_standard") != STANDARD_ID:
            raise ValueError("Captured input uses another gesture convention")
        data = (args.dataset / metadata["input_file"]).read_bytes()
        if len(data) != 4096:
            raise ValueError(f"Bad captured input length: {path}")
        import hashlib
        if hashlib.sha256(data).hexdigest() != metadata["sha256"]:
            raise ValueError(f"Captured input checksum changed: {path}")
        output = integer_forward(np.frombuffer(data, dtype=np.uint8).reshape(64, 64), arrays).reshape(16, 27)
        predicted, object_score, margin = prediction_for_output(output, model, args.mode)
        expected = metadata["label"]
        if expected is not None and expected not in digit_indices:
            raise ValueError("Captured ground-truth label is outside the selected model classes")
        confusion[unknown if expected is None else digit_indices[expected], unknown if predicted is None else digit_indices[predicted]] += 1
        predictions.append(dict(sample=path.name, expected=expected, predicted=predicted, object_score=object_score, margin=margin, session=metadata["session"], card_id=metadata["card_id"]))
    positives = int(confusion[:unknown].sum())
    correct = int(np.trace(confusion[:unknown, :unknown]))
    rejected = int(confusion[:unknown, unknown].sum())
    result = dict(mode=args.mode, gesture_standard=model.get("gesture_standard"), domain="Captured physical FPGA model inputs, evaluated offline with exact integer arithmetic; not board throughput or application event accuracy", samples=len(records), sessions=sorted({row["session"] for row in predictions}), cards=sorted({row["card_id"] for row in predictions}), positive_samples=positives, correct=correct, rejected_positive=rejected, wrong_positive=positives - correct - rejected, negative_samples=int(confusion[unknown].sum()), negative_false_accepts=int(confusion[unknown, :unknown].sum()), confusion_labels=digits + ["reject/no-target"], confusion=confusion.tolist(), predictions=predictions)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in result.items() if key not in ["predictions", "confusion"]}, indent=2))


if __name__ == "__main__":
    main()
