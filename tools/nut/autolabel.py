"""Auto-label a folder of raw photos with the 2M teacher -> repo-format annotations.

Why this exists
---------------
The nut dataset (`nut_dataset_unlit_bright_augmented_7to1`) is gone and cannot be
recovered: the delivered bundle never contained `datasets/`, the two upstream
source datasets that fed the merge script are gone too, and no copy exists on any
visible drive (see `results/NUT-DATA-STATUS.md`).  The only way to a nut model now
is new photographs -- and hand-drawing boxes for 300+ photos is what actually
blocks that path, not the photography.

The 2M teacher (`models/nuts/best_model.pt`, F1 0.9958 on 2,280 real frames) can
label them instead.  This script does exactly that and writes the same CSV schema
`multi_dataset.read_multi_split` consumes, so the output drops straight into
`train_slim.py`.

Trust is established, not assumed
---------------------------------
`--compare-gt` scores the auto-labels against a real ground-truth CSV.  Run it on
the bottle-cap dataset (which still has GT) to reproduce the teacher's published
F1: if this script reproduces ~0.995 there, the same code path labelling your
photos is trustworthy.  That self-test is the acceptance gate for this tool.

Usage
-----
    # acceptance self-test: teacher vs real GT on the bottle-cap test split
    python tools/nut/autolabel.py --images <cap_dataset>/test \
        --teacher tools/bottlecap/model_src/best_model.pt \
        --gt-csv <cap_dataset>/test_annotations.csv \
        --limit 200 --out-dir .tmp/nut/selftest

    # label fresh photos
    python tools/nut/autolabel.py --images D:/photos/nut_raw \
        --teacher "D:/USER/Desktop/04_models_training_code_and_reports(1)/models/nuts/best_model.pt" \
        --out-dir results/nut/autolabel --overlay-dir results/nut/autolabel/overlay
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from collections import Counter
from pathlib import Path

import numpy as np
import torch
from PIL import Image, ImageDraw

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tools" / "bottlecap" / "model_src"))

from nut_detector.enhanced_anchor_free import EnhancedNutAnchorFree  # noqa: E402
from nut_detector.mobilenet_anchor_free import MobileNetNutAnchorFree  # noqa: E402
from nut_detector.mobilenet_anchor_free_slim import SlimMobileNetNutAnchorFree  # noqa: E402
from nut_detector.multi_anchor_free import decode_multi_predictions  # noqa: E402

IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".bmp", ".webp"}
# palette reused by the overlay so a class keeps its colour across images
PALETTE = [(66, 214, 102), (255, 92, 92), (93, 158, 255), (255, 205, 71)]
DEFAULT_CLASS_NAMES = ["chickpea", "cashew", "almond", "walnut"]


# --------------------------------------------------------------------------- #
# preprocessing -- must stay bit-identical to train_slim.make_preprocess
# --------------------------------------------------------------------------- #
def preprocess(image: Image.Image, input_size: int, aspect_ratio: float) -> torch.Tensor:
    """Letterbox to ``input_size x round(aspect*input_size)`` then edge-pad to square."""
    fitted_height = int(round(input_size * aspect_ratio))
    top = (input_size - fitted_height) // 2
    bottom = input_size - fitted_height - top
    resized = image.resize((input_size, fitted_height), Image.Resampling.BILINEAR)
    pixels = np.asarray(resized)
    pixels = np.pad(pixels, ((top, bottom), (0, 0), (0, 0)), mode="edge").copy()
    tensor = torch.from_numpy(pixels).permute(2, 0, 1).float().div_(127.5).sub_(1.0)
    return tensor


def boxes_to_source(
    boxes: torch.Tensor, image_size: tuple[int, int], input_size: int, aspect_ratio: float
) -> np.ndarray:
    """Invert ``preprocess``: normalized xyxy on the padded tensor -> source pixels."""
    width, height = image_size
    fitted_height = int(round(input_size * aspect_ratio))
    top = (input_size - fitted_height) // 2
    xyxy = boxes.detach().cpu().numpy().astype(np.float64) * (input_size - 1)
    xyxy[:, [0, 2]] *= width / input_size
    xyxy[:, [1, 3]] = (xyxy[:, [1, 3]] - top) * height / fitted_height
    xyxy[:, [0, 2]] = np.clip(np.rint(xyxy[:, [0, 2]]), 0, width - 1)
    xyxy[:, [1, 3]] = np.clip(np.rint(xyxy[:, [1, 3]]), 0, height - 1)
    # drop degenerate boxes produced by clipping at the pad boundary
    keep = (xyxy[:, 2] - xyxy[:, 0] >= 2) & (xyxy[:, 3] - xyxy[:, 1] >= 2)
    return xyxy[keep], keep


# --------------------------------------------------------------------------- #
# model
# --------------------------------------------------------------------------- #
def build_model(checkpoint: dict, device: torch.device) -> tuple[torch.nn.Module, list[str]]:
    class_names = list(checkpoint.get("class_names") or DEFAULT_CLASS_NAMES)
    num_classes = len(class_names)
    if checkpoint.get("model_variant") == "enhanced_mobilenetv2_fpn_decoupled_head":
        model = EnhancedNutAnchorFree(
            num_classes=num_classes,
            fpn_channels=int(checkpoint.get("fpn_channels", 128)),
            backbone_width=float(checkpoint.get("backbone_width", 1.0)),
        )
    elif "width_multiplier" in checkpoint:
        model = SlimMobileNetNutAnchorFree(
            num_classes=num_classes,
            width_multiplier=float(checkpoint["width_multiplier"]),
            fpn_channels=int(checkpoint["fpn_channels"]),
        )
    else:
        model = MobileNetNutAnchorFree(num_classes=num_classes)
    model.load_state_dict(checkpoint["model"])
    return model.to(device).eval(), class_names


# --------------------------------------------------------------------------- #
# ground-truth comparison (only used by --compare-gt)
# --------------------------------------------------------------------------- #
def load_gt(path: Path) -> dict[str, list[tuple[int, int, int, int, int]]]:
    grouped: dict[str, list[tuple[int, int, int, int, int]]] = {}
    with path.open(encoding="utf-8-sig") as file:
        for row in csv.DictReader(file):
            grouped.setdefault(row["image"], []).append(
                (
                    int(row["class_id"]),
                    int(row["x_min"]),
                    int(row["y_min"]),
                    int(row["x_max"]),
                    int(row["y_max"]),
                )
            )
    for rows in grouped.values():
        rows.sort()
    return grouped


def iou_matrix(pred: np.ndarray, gt: np.ndarray) -> np.ndarray:
    if len(pred) == 0 or len(gt) == 0:
        return np.zeros((len(pred), len(gt)), dtype=np.float64)
    px1, py1, px2, py2 = pred.T
    gx1, gy1, gx2, gy2 = gt.T
    ix1, iy1 = np.maximum(px1[:, None], gx1[None, :]), np.maximum(py1[:, None], gy1[None, :])
    ix2, iy2 = np.minimum(px2[:, None], gx2[None, :]), np.minimum(py2[:, None], gy2[None, :])
    inter = np.clip(ix2 - ix1, 0, None) * np.clip(iy2 - iy1, 0, None)
    area_p = (px2 - px1) * (py2 - py1)
    area_g = (gx2 - gx1) * (gy2 - gy1)
    return inter / np.maximum(area_p[:, None] + area_g[None, :] - inter, 1e-9)


def match(
    pred_cls: np.ndarray, pred_box: np.ndarray, gt_rows: list[tuple[int, int, int, int, int]]
) -> list[float]:
    """Greedy IoU>=0.5 same-class matching -- identical rule to evaluate_multi."""
    if not gt_rows:
        return []
    gt_cls = np.array([row[0] for row in gt_rows])
    gt_box = np.array([row[1:] for row in gt_rows], dtype=np.float64)
    ious = iou_matrix(pred_box, gt_box)
    ious[pred_cls[:, None] != gt_cls[None, :]] = -1.0
    pairs = []
    while ious.size and ious.max() >= 0.5:
        flat = int(ious.argmax())
        i, j = divmod(flat, ious.shape[1])
        pairs.append(float(ious[i, j]))
        ious[i, :] = -1.0
        ious[:, j] = -1.0
    return pairs


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
def main() -> None:
    parser = argparse.ArgumentParser(description="Teacher auto-labelling for raw photos")
    parser.add_argument("--images", type=Path, required=True, help="folder of raw photos")
    parser.add_argument("--teacher", type=Path, required=True, help="2M checkpoint (.pt)")
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--input-size", type=int, default=224)
    parser.add_argument("--aspect-ratio", type=float, default=0.75,
                        help="0.75 = 4:3 letterbox (teacher's training geometry), 1.0 = square")
    parser.add_argument("--min-conf", type=float, default=0.20)
    parser.add_argument("--max-detections", type=int, default=4)
    parser.add_argument("--limit", type=int, default=0, help="only the first N images")
    parser.add_argument("--gt-csv", type=Path, default=None,
                        help="optional ground truth: scores the auto-labels (F1 / mIoU)")
    parser.add_argument("--overlay-dir", type=Path, default=None,
                        help="write images with predicted boxes drawn, for eyeballing")
    parser.add_argument("--device", default="cuda")
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    if args.overlay_dir:
        args.overlay_dir.mkdir(parents=True, exist_ok=True)

    device = torch.device(args.device if torch.cuda.is_available() else "cpu")
    checkpoint = torch.load(args.teacher, map_location="cpu", weights_only=False)
    model, class_names = build_model(checkpoint, device)

    images = sorted(p for p in args.images.iterdir() if p.suffix.lower() in IMAGE_SUFFIXES)
    if args.limit:
        images = images[: args.limit]
    if not images:
        raise SystemExit(f"no images found in {args.images}")

    gt = load_gt(args.gt_csv) if args.gt_csv else None
    rows: list[dict[str, object]] = []
    class_counter: Counter[int] = Counter()
    per_image_count: Counter[int] = Counter()
    matched_ious: list[float] = []
    tp = fp = fn = 0
    skipped = 0

    with torch.no_grad():
        for index, path in enumerate(images):
            with Image.open(path) as handle:
                image = handle.convert("RGB")
            tensor = preprocess(image, args.input_size, args.aspect_ratio).unsqueeze(0).to(device)
            predictions = decode_multi_predictions(
                *model(tensor),
                max_detections=args.max_detections,
                confidence_threshold=args.min_conf,
            )[0]
            boxes, keep = boxes_to_source(
                predictions["boxes"], image.size, args.input_size, args.aspect_ratio
            )
            classes = predictions["classes"].detach().cpu().numpy()[keep] + 1  # 1-based
            scores = predictions["scores"].detach().cpu().numpy()[keep]

            if len(boxes) == 0:
                skipped += 1
            per_image_count[len(boxes)] += 1
            for object_index, ((x1, y1, x2, y2), class_id, score) in enumerate(
                zip(boxes.tolist(), classes.tolist(), scores.tolist())
            ):
                rows.append(
                    {
                        "image": path.name,
                        "label": "",
                        "object_index": object_index,
                        "class_id": int(class_id),
                        "class_name": class_names[int(class_id) - 1] if int(class_id) <= len(class_names) else "",
                        "x_min": int(x1), "y_min": int(y1), "x_max": int(x2), "y_max": int(y2),
                        "width": image.width, "height": image.height,
                        "confidence": round(float(score), 4),
                        "source": "auto",
                    }
                )
                class_counter[int(class_id)] += 1

            if gt is not None and path.name in gt:
                gt_rows = gt[path.name]
                pairs = match(classes, boxes, gt_rows)
                tp += len(pairs)
                fp += len(boxes) - len(pairs)
                fn += len(gt_rows) - len(pairs)
                matched_ious.extend(pairs)

            if args.overlay_dir:
                canvas = image.copy()
                draw = ImageDraw.Draw(canvas)
                for (x1, y1, x2, y2), class_id in zip(boxes.tolist(), classes.tolist()):
                    color = PALETTE[(int(class_id) - 1) % len(PALETTE)]
                    draw.rectangle((x1, y1, x2, y2), outline=color, width=2)
                canvas.save(args.overlay_dir / path.name)

            if (index + 1) % 50 == 0:
                print(f"  {index + 1}/{len(images)} labelled", flush=True)

    annotation_path = args.out_dir / "annotations.csv"
    with annotation_path.open("w", newline="", encoding="utf-8-sig") as file:
        writer = csv.DictWriter(file, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)

    summary: dict[str, object] = {
        "teacher": str(args.teacher),
        "teacher_epoch": checkpoint.get("epoch"),
        "images": len(images),
        "objects": len(rows),
        "images_without_detection": skipped,
        "objects_per_image": {str(k): v for k, v in sorted(per_image_count.items())},
        "objects_per_class": {
            (class_names[c - 1] if c <= len(class_names) else str(c)): n
            for c, n in sorted(class_counter.items())
        },
        "input_size": args.input_size,
        "aspect_ratio": args.aspect_ratio,
        "min_conf": args.min_conf,
        "annotations": str(annotation_path),
    }
    if gt is not None:
        precision = tp / max(1, tp + fp)
        recall = tp / max(1, tp + fn)
        summary["vs_ground_truth"] = {
            "images_scored": sum(1 for p in images if p.name in gt),
            "true_positive": tp, "false_positive": fp, "false_negative": fn,
            "precision": round(precision, 6), "recall": round(recall, 6),
            "f1": round(2 * precision * recall / max(1e-9, precision + recall), 6),
            "mean_matched_iou": round(float(np.mean(matched_ious)), 6) if matched_ious else 0.0,
        }
    (args.out_dir / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
