from __future__ import annotations

import argparse
import json
from pathlib import Path

import onnx
import onnxruntime as ort
import torch

from .config import PROJECT_ROOT
from .mobilenet_anchor_free import MobileNetNutAnchorFree
from .mobilenet_anchor_free_slim import SlimMobileNetNutAnchorFree
from .enhanced_anchor_free import EnhancedNutAnchorFree


def main() -> None:
    parser = argparse.ArgumentParser(description="Export MobileNet detector to ONNX")
    parser.add_argument(
        "--checkpoint",
        type=Path,
        default=PROJECT_ROOT / "runs" / "mobilenet_nut_anchor_free" / "best_model.pt",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=PROJECT_ROOT / "runs" / "mobilenet_nut_anchor_free",
    )
    parser.add_argument("--output-name", default="mobilenet_nut_anchor_free.onnx")
    args = parser.parse_args()
    run_dir = args.output_dir
    run_dir.mkdir(parents=True, exist_ok=True)
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    if checkpoint.get("model_variant") == "enhanced_mobilenetv2_fpn_decoupled_head":
        model = EnhancedNutAnchorFree(
            num_classes=4,
            fpn_channels=int(checkpoint.get("fpn_channels", 128)),
            backbone_width=float(checkpoint.get("backbone_width", 1.0)),
        )
    elif "width_multiplier" in checkpoint:
        model = SlimMobileNetNutAnchorFree(
            num_classes=4,
            width_multiplier=float(checkpoint["width_multiplier"]),
            fpn_channels=int(checkpoint["fpn_channels"]),
        )
    else:
        model = MobileNetNutAnchorFree(num_classes=4)
    model.load_state_dict(checkpoint["model"])
    model.eval()
    output = run_dir / args.output_name
    example = torch.zeros(1, 3, 224, 224)
    torch.onnx.export(
        model,
        example,
        output,
        input_names=["image"],
        output_names=["objectness_map", "class_map", "box_map"],
        opset_version=17,
        dynamo=False,
    )
    graph = onnx.load(output)
    onnx.checker.check_model(graph)
    session = ort.InferenceSession(str(output), providers=["CPUExecutionProvider"])
    outputs = session.run(None, {"image": example.numpy()})
    report = {
        "checkpoint_epoch": checkpoint["epoch"],
        "domain": checkpoint.get("domain", "nut"),
        "class_names": checkpoint.get("class_names", ["chickpea", "cashew", "almond", "walnut"]),
        "onnx_path": str(output),
        "onnx_bytes": output.stat().st_size,
        "onnx_mib": output.stat().st_size / 1024**2,
        "input_shape": [1, 3, 224, 224],
        "output_shapes": [list(value.shape) for value in outputs],
        "onnx_checker": "PASS",
        "onnxruntime_inference": "PASS",
    }
    (run_dir / "export_report.json").write_text(
        json.dumps(report, indent=2), encoding="utf-8"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
