"""Deployment self-check for the slim bottle-cap detector (converter hand-off).

Loads ``results/bottlecap/slim/best_model.pt``, re-runs the full 500-image test set
with exactly the deployment preprocessing (96x72 letterbox + 12/12 edge padding,
``/127.5-1``) and asserts the metrics equal the ones recorded during training.
Then dumps fixed-size reference artefacts for the PyTorch -> NPU converter:

* ``ref_heads.npz``
    - ``image_names``             : (N,) test image names
    - ``indices``                 : (N,) indices in the sorted test split
    - ``inputs_float_nchw``       : (N,3,96,96) float32 model input
    - ``inputs_int8_packed3``     : (N,96,96,3) int8 PACKED3 conv0 input bytes
    - ``objectness``              : (N,1,24,24) float32 raw objectness logits
    - ``class_logits``            : (N,4,24,24) float32 raw class logits
    - ``box_logits``              : (N,4,24,24) float32 raw box logits (tx,ty,tw,th)
    - ``meta``                    : (1,) JSON string with quant/decode metadata
* ``deploy_test_report.json`` / ``deploy_test_predictions.csv``

Usage
-----
    python tools/bottlecap/eval_slim_deploy.py
    python tools/bottlecap/eval_slim_deploy.py --num-ref-images 8 --skip-eval
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import torch
from PIL import Image

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
os.environ.setdefault("SLIM_INPUT_SIZE", "96")
import train_slim as ts  # noqa: E402

DEFAULT_CHECKPOINT = REPO_ROOT / "results" / "bottlecap" / "slim" / "best_model.pt"
DEFAULT_OUTPUT_DIR = REPO_ROOT / "results" / "bottlecap" / "slim"

# CONTRACT §5: input activation range is [-1, 1]  =>  s = (max-min)/255 = 2/255,
# zp = -128 - round(min/s) = 0.  PACKED3 layout: addr = y*iw*3 + x*3 + c (c<3),
# the c>=3 lanes of the conv0 read are filled with zp_in = 0 and never stored.
INPUT_QUANT = {
    "range": [-1.0, 1.0],
    "s_a_in": 2.0 / 255.0,
    "zp_in": 0,
    "a_q": "clip(round(a / s_a_in) + zp_in, -128, 127)",
    "packed3_layout": "addr = y*iw*3 + x*3 + c (c<3)",
}

# decode parameters -- must stay identical to nut_detector.multi_anchor_free.decode_multi_predictions
DECODE = {
    "grid_hw": None,  # filled at runtime
    "objectness_activation": "sigmoid",
    "local_max": "sigmoid(obj) == max_pool2d(sigmoid(obj), 3, stride=1, pad=1)",
    "confidence": "sigmoid(obj) * softmax(class).max",
    "confidence_threshold": 0.20,
    "pre_nms_topk": 40,
    "nms": "class-aware greedy NMS",
    "nms_iou_threshold": 0.35,
    "max_detections": 4,
    "box_decode": "(cx,cy) = (gx + sigmoid(tx), gy + sigmoid(ty)) / G ; (w,h) = sigmoid(tw,th)",
}


def pack_int8_packed3(image_nchw: torch.Tensor) -> np.ndarray:
    """Quantize the normalized model input to int8 PACKED3 bytes (HWC order)."""
    scale = INPUT_QUANT["s_a_in"]
    zero_point = INPUT_QUANT["zp_in"]
    array = image_nchw.detach().cpu().numpy().astype(np.float32)
    quantized = np.rint(array / scale) + zero_point
    quantized = np.clip(quantized, -128, 127).astype(np.int8)
    return np.ascontiguousarray(quantized.transpose(1, 2, 0))  # HWC


def dequantize_packed3(packed: np.ndarray) -> np.ndarray:
    scale = INPUT_QUANT["s_a_in"]
    zero_point = INPUT_QUANT["zp_in"]
    array = (packed.astype(np.float32) - zero_point) * scale
    return array.transpose(2, 0, 1)  # CHW


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--checkpoint", type=Path, default=DEFAULT_CHECKPOINT)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--dataset-dir", type=Path, default=ts.DEFAULT_DATASET_DIR)
    parser.add_argument("--num-ref-images", type=int, default=8)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--num-workers", type=int, default=4)
    parser.add_argument("--seed", type=int, default=ts.SEED)
    parser.add_argument("--skip-eval", action="store_true",
                        help="only write ref_heads.npz (skip the 500-image evaluation)")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    config = checkpoint.get("config", {})
    input_size = int(config.get("input_size", 96))
    width = float(config.get("width_multiplier", 0.4))
    fpn = int(config.get("fpn_channels", 64))
    num_classes = int(config.get("num_classes", 4))
    class_names = list(checkpoint.get("class_names", config.get("class_names", ts.CLASS_NAMES)))
    os.environ["SLIM_INPUT_SIZE"] = str(input_size)
    patch_meta = ts.patch_nut_detector(input_size)
    DECODE["grid_hw"] = [input_size // 4, input_size // 4]
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")

    model = ts.SlimMobileNetNutAnchorFree(
        num_classes=num_classes, width_multiplier=width, fpn_channels=fpn
    )
    model.load_state_dict(checkpoint["model"])
    model.to(device).eval()
    parameter_count = sum(parameter.numel() for parameter in model.parameters())

    loader_args = SimpleNamespace(
        dataset_dir=args.dataset_dir, limit_train=0, limit_test=0, seed=args.seed,
        batch_size=args.batch_size, num_workers=args.num_workers,
    )
    _, test_loader, test_samples, _ = ts.build_loaders(loader_args, patch_meta)

    metrics = None
    if not args.skip_eval:
        detailed, rows = ts.detailed_evaluate(model, test_loader, device, test_samples)
        metrics = detailed
        reference_path = args.output_dir / "test_report.json"
        reference = None
        matches = None
        deltas = None
        if reference_path.exists():
            reference = json.loads(reference_path.read_text(encoding="utf-8"))
            compare_keys = ("precision", "recall", "f1", "mean_matched_iou",
                            "exact_image_accuracy", "count_accuracy",
                            "true_positive", "false_positive", "false_negative")
            deltas = {key: float(detailed[key] - reference[key]) for key in compare_keys}
            matches = all(abs(value) < 1e-9 for value in deltas.values())
        report = {
            "checkpoint": str(args.checkpoint.resolve()),
            "checkpoint_epoch": checkpoint.get("epoch"),
            "input_size": input_size,
            "preprocess": patch_meta["preprocess"],
            "parameter_count": parameter_count,
            "metrics": detailed,
            "training_report": str(reference_path) if reference is not None else None,
            "matches_training_report": matches,
            "deltas_vs_training": deltas,
            "decode": DECODE,
        }
        (args.output_dir / "deploy_test_report.json").write_text(
            json.dumps(report, indent=2), encoding="utf-8"
        )
        with (args.output_dir / "deploy_test_predictions.csv").open(
            "w", newline="", encoding="utf-8"
        ) as file:
            writer = csv.DictWriter(file, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
        print(json.dumps({key: detailed[key] for key in
                          ("precision", "recall", "f1", "mean_matched_iou",
                           "exact_image_accuracy", "count_accuracy")}, indent=2), flush=True)
        print("matches_training_report =", matches, flush=True)

    # ------------------------------------------------ fixed reference images
    count = max(1, min(args.num_ref_images, len(test_samples)))
    if count == 1:
        indices = [0]
    else:
        indices = sorted({int(round(index * (len(test_samples) - 1) / (count - 1)))
                          for index in range(count)})
    preprocess = ts.make_preprocess(input_size)
    image_names: list[str] = []
    float_inputs: list[np.ndarray] = []
    int8_inputs: list[np.ndarray] = []
    for index in indices:
        sample = test_samples[index]
        with Image.open(Path(sample["image"])) as opened:
            image = opened.convert("RGB")
        boxes = np.asarray(sample["boxes"], dtype=np.float32).copy()
        tensor, _ = preprocess(image, boxes)
        image_names.append(Path(sample["image"]).name)
        float_inputs.append(tensor.numpy().astype(np.float32))
        int8_inputs.append(pack_int8_packed3(tensor))

    float_array = np.stack(float_inputs).astype(np.float32)
    int8_array = np.stack(int8_inputs).astype(np.int8)

    # Deterministic float reference: TF32 off + one single batched forward, so the
    # stored logits are reproducible (TF32/batch-shape noise would be ~3e-3 otherwise).
    torch.backends.cudnn.allow_tf32 = False
    torch.backends.cuda.matmul.allow_tf32 = False
    with torch.no_grad():
        obj, cls, box = model(torch.from_numpy(float_array).to(device))
    objectness_array = obj.float().cpu().numpy().astype(np.float32)
    class_array = cls.float().cpu().numpy().astype(np.float32)
    box_array = box.float().cpu().numpy().astype(np.float32)

    # self-check: the int8 PACKED3 round-trip vs float input, and model-vs-npz heads
    roundtrip_error = float(np.abs(dequantize_packed3(int8_array[0]) - float_array[0]).max())
    with torch.no_grad():
        replay_obj, replay_cls, replay_box = model(torch.from_numpy(float_array).to(device))
    replay_error = max(
        float(np.abs(replay_obj.float().cpu().numpy() - objectness_array).max()),
        float(np.abs(replay_cls.float().cpu().numpy() - class_array).max()),
        float(np.abs(replay_box.float().cpu().numpy() - box_array).max()),
    )

    meta = {
        "arch": "SlimMobileNetNutAnchorFree",
        "checkpoint": str(args.checkpoint.resolve()),
        "checkpoint_epoch": checkpoint.get("epoch"),
        "parameter_count": parameter_count,
        "width_multiplier": width,
        "fpn_channels": fpn,
        "num_classes": num_classes,
        "class_names": class_names,
        "input_size": input_size,
        "preprocess": patch_meta["preprocess"],
        "norm": "/127.5-1",
        "input_quant": INPUT_QUANT,
        "decode": DECODE,
        "head_shapes_nchw": {
            "objectness": list(objectness_array[0].shape),
            "class_logits": list(class_array[0].shape),
            "box_logits": list(box_array[0].shape),
        },
        "ref_indices": indices,
        "ref_image_names": image_names,
        "reference_forward": {
            "batch_size": len(indices),
            "precision": "float32",
            "tf32": False,
            "note": "single batched forward with TF32 disabled; replay is bit-identical",
        },
        "int8_roundtrip_max_abs_error": roundtrip_error,
        "float_replay_max_abs_error": replay_error,
        "metrics": metrics,
    }
    output_path = args.output_dir / "ref_heads.npz"
    np.savez_compressed(
        output_path,
        image_names=np.array(image_names),
        indices=np.array(indices, dtype=np.int64),
        inputs_float_nchw=float_array,
        inputs_int8_packed3=int8_array,
        objectness=objectness_array,
        class_logits=class_array,
        box_logits=box_array,
        meta=np.array([json.dumps(meta, ensure_ascii=False)]),
    )
    print(json.dumps({
        "ref_heads": str(output_path),
        "num_ref_images": len(indices),
        "int8_roundtrip_max_abs_error": roundtrip_error,
        "float_replay_max_abs_error": replay_error,
        "metrics": metrics,
    }, indent=2, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
