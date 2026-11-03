from __future__ import annotations

import json

import onnx
import onnxruntime as ort
import torch

from .anchor_free import TinyNutAnchorFree
from .config import PROJECT_ROOT


def main() -> None:
    run_dir = PROJECT_ROOT / "runs" / "tiny_nut_anchor_free"
    checkpoint = torch.load(run_dir / "best_model.pt", map_location="cpu", weights_only=False)
    model = TinyNutAnchorFree(num_classes=4)
    model.load_state_dict(checkpoint["model"])
    model.eval()
    output_path = run_dir / "tiny_nut_anchor_free.onnx"
    example = torch.zeros(1, 3, 224, 224)
    torch.onnx.export(
        model,
        example,
        output_path,
        input_names=["image"],
        output_names=["objectness_map", "class_map", "box_map"],
        opset_version=17,
        dynamo=False,
    )
    graph = onnx.load(output_path)
    onnx.checker.check_model(graph)
    session = ort.InferenceSession(str(output_path), providers=["CPUExecutionProvider"])
    outputs = session.run(None, {"image": example.numpy()})
    report = {
        "onnx_path": str(output_path),
        "onnx_bytes": output_path.stat().st_size,
        "onnx_mib": output_path.stat().st_size / 1024**2,
        "input_shape": [1, 3, 224, 224],
        "output_shapes": [list(value.shape) for value in outputs],
        "onnx_checker": "PASS",
        "onnxruntime_inference": "PASS",
        "note": "ArgMax and grid decoding remain outside the NPU graph.",
    }
    (run_dir / "export_report.json").write_text(
        json.dumps(report, indent=2), encoding="utf-8"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
