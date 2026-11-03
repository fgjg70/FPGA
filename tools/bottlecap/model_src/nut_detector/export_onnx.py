from __future__ import annotations

import argparse
import json
from pathlib import Path

import onnx
import onnxruntime as ort
import torch

from .config import PROJECT_ROOT
from .model import ExportModel, TinyNutFPN


def main() -> None:
    parser = argparse.ArgumentParser(description="Export and verify the nut detector ONNX")
    parser.add_argument(
        "--checkpoint",
        type=Path,
        default=PROJECT_ROOT / "runs" / "tiny_nut_fpn" / "best_model.pt",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=PROJECT_ROOT / "runs" / "tiny_nut_fpn" / "tiny_nut_fpn.onnx",
    )
    args = parser.parse_args()

    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    model = TinyNutFPN(num_classes=4)
    model.load_state_dict(checkpoint["model"])
    export_model = ExportModel(model.eval())
    example = torch.zeros(1, 3, 224, 224)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    torch.onnx.export(
        export_model,
        example,
        args.output,
        input_names=["image"],
        output_names=["class_probabilities", "bbox_xyxy_normalized"],
        opset_version=17,
        dynamo=False,
    )
    graph = onnx.load(args.output)
    onnx.checker.check_model(graph)
    session = ort.InferenceSession(str(args.output), providers=["CPUExecutionProvider"])
    outputs = session.run(None, {"image": example.numpy()})
    report = {
        "onnx_path": str(args.output),
        "onnx_bytes": args.output.stat().st_size,
        "onnx_mib": args.output.stat().st_size / 1024**2,
        "input_shape": [1, 3, 224, 224],
        "class_output_shape": list(outputs[0].shape),
        "bbox_output_shape": list(outputs[1].shape),
        "onnx_checker": "PASS",
        "onnxruntime_inference": "PASS",
    }
    (args.output.parent / "export_report.json").write_text(
        json.dumps(report, indent=2), encoding="utf-8"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()

