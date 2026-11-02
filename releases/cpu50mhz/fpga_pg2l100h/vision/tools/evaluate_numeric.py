import argparse
import json
from pathlib import Path
import sys

import numpy as np
import torch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "model"))
from network import integer_forward


def main():
    parser = argparse.ArgumentParser(description="Evaluate exact captured FPGA inputs against human supplied ground truth, including rejects and negative false positives")
    parser.add_argument("--mode", choices=["label", "hand"], default="label")
    parser.add_argument("--dataset", type=Path)
    parser.add_argument("--split", choices=["val", "test"], default="test")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/real_camera_report.json")
    args = parser.parse_args()
    model_dir = ROOT / "model/gesture" if args.mode == "hand" else ROOT / "model"
    model = json.loads((model_dir / "model.json").read_text(encoding="utf-8"))
    args.dataset = args.dataset or ROOT / "model/checkpoints" / ("camera_hand" if args.mode == "hand" else "camera_numeric")
    enabled = list(range(3, 12)) if args.mode == "hand" else list(range(12, 22))
    if model["enabled_classes"] != enabled:
        raise ValueError("Model classes do not match the requested input mode")
    torch.set_num_threads(4)
    records = sorted((args.dataset / "metadata" / args.split).glob("*.json"))
    if not records:
        raise ValueError("No captures exist; real-camera accuracy cannot be reported before collecting data")
    with np.load(model_dir / "micro_yolo.npz", allow_pickle=False) as archive:
        arrays = dict(archive)
    confusion = np.zeros((11, 11), dtype=np.int64)
    predictions = []
    for path in records:
        metadata = json.loads(path.read_text(encoding="utf-8"))
        if metadata.get("mode", "label") != args.mode:
            raise ValueError("Captured input mode does not match the model")
        data = (args.dataset / metadata["input_file"]).read_bytes()
        if len(data) != 4096:
            raise ValueError(f"Bad captured input length: {path}")
        import hashlib
        if hashlib.sha256(data).hexdigest() != metadata["sha256"]:
            raise ValueError(f"Captured input checksum changed: {path}")
        output = integer_forward(np.frombuffer(data, dtype=np.uint8).reshape(64, 64), arrays).reshape(16, 27)
        cell = output[int(np.argmax(output[:, 0]))]
        class_scores = [int(cell[5 + category]) for category in enabled]
        scores = sorted(class_scores, reverse=True)
        accepted = int(cell[0]) >= model["object_threshold"] and scores[0] - scores[1] >= model.get("class_margin_threshold", 24)
        predicted = int(np.argmax(class_scores)) + (1 if args.mode == "hand" else 0) if accepted else 10
        expected = 10 if metadata["label"] is None else int(metadata["label"])
        confusion[expected, predicted] += 1
        predictions.append(dict(sample=path.name, expected=expected, predicted=predicted, object_score=int(cell[0]), margin=scores[0] - scores[1], session=metadata["session"], card_id=metadata["card_id"]))
    positives = int(confusion[:10].sum())
    correct = int(np.trace(confusion[:10, :10]))
    rejected = int(confusion[:10, 10].sum())
    result = dict(mode=args.mode, domain="Captured physical FPGA model inputs, evaluated offline with exact integer arithmetic; not board throughput or application event accuracy", samples=len(records), sessions=sorted({row["session"] for row in predictions}), cards=sorted({row["card_id"] for row in predictions}), positive_samples=positives, correct=correct, rejected_positive=rejected, wrong_positive=positives - correct - rejected, negative_samples=int(confusion[10].sum()), negative_false_accepts=int(confusion[10, :10].sum()), confusion_labels=list(range(10)) + ["reject/no-target"], confusion=confusion.tolist(), predictions=predictions)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in result.items() if key not in ["predictions", "confusion"]}, indent=2))


if __name__ == "__main__":
    main()
