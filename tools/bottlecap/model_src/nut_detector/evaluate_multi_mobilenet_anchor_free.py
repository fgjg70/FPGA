from __future__ import annotations

import argparse
import csv
import json
import random
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np
import torch
from PIL import Image, ImageDraw
from torch.utils.data import DataLoader

from .config import PROJECT_ROOT
from .mobilenet_anchor_free import MobileNetNutAnchorFree
from .mobilenet_anchor_free_slim import SlimMobileNetNutAnchorFree
from .enhanced_anchor_free import EnhancedNutAnchorFree
from .multi_anchor_free import decode_multi_predictions
from .multi_dataset import MultiNutDataset, read_multi_split
from .train_multi_mobilenet_anchor_free import pairwise_iou


DEFAULT_CLASS_NAMES = ["chickpea", "cashew", "almond", "walnut"]


def box_to_source(box: np.ndarray) -> tuple[int, int, int, int]:
    x1, y1, x2, y2 = box * 223.0
    return (
        int(np.clip(round(x1 * 320 / 224), 0, 319)),
        int(np.clip(round((y1 - 28) * 240 / 168), 0, 239)),
        int(np.clip(round(x2 * 320 / 224), 0, 319)),
        int(np.clip(round((y2 - 28) * 240 / 168), 0, 239)),
    )


def matched_pairs(
    predicted_classes: torch.Tensor,
    predicted_boxes: torch.Tensor,
    true_classes: torch.Tensor,
    true_boxes: torch.Tensor,
) -> list[tuple[int, int, float]]:
    if len(predicted_boxes) == 0:
        return []
    ious = pairwise_iou(predicted_boxes, true_boxes)
    candidate = ious.masked_fill(
        ~predicted_classes[:, None].eq(true_classes[None, :]), -1.0
    )
    pairs: list[tuple[int, int, float]] = []
    while candidate.numel() and float(candidate.max()) >= 0.5:
        flat = int(candidate.argmax())
        predicted_index = flat // candidate.shape[1]
        true_index = flat % candidate.shape[1]
        pairs.append((predicted_index, true_index, float(candidate[predicted_index, true_index])))
        candidate[predicted_index, :] = -1.0
        candidate[:, true_index] = -1.0
    return pairs


def main() -> None:
    parser = argparse.ArgumentParser(description="Detailed multi-object evaluation")
    parser.add_argument(
        "--checkpoint",
        type=Path,
        default=PROJECT_ROOT / "runs" / "mobilenet_nut_multi_anchor_free" / "best_model.pt",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=PROJECT_ROOT / "runs" / "mobilenet_nut_multi_anchor_free",
    )
    parser.add_argument(
        "--dataset-dir",
        type=Path,
        default=PROJECT_ROOT / "nut_dataset_multi_7to1",
    )
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    dataset_dir = args.dataset_dir
    samples = read_multi_split(dataset_dir, "test")
    dataset = MultiNutDataset(samples, training=False, seed=20260805)
    loader = DataLoader(dataset, batch_size=32, shuffle=False)
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    class_names = list(checkpoint.get("class_names", DEFAULT_CLASS_NAMES))
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
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    model.to(device).eval()

    image_rows: list[dict[str, object]] = []
    true_by_class: Counter[int] = Counter()
    predicted_by_class: Counter[int] = Counter()
    matched_by_class: Counter[int] = Counter()
    matched_ious: list[float] = []
    grouped_metrics: dict[int, Counter[str]] = defaultdict(Counter)
    lighting_metrics: dict[str, Counter[str]] = defaultdict(Counter)
    offset = 0
    with torch.no_grad():
        for images, classes, boxes, valid in loader:
            images = images.to(device)
            classes = classes.to(device)
            boxes = boxes.to(device)
            valid = valid.to(device)
            outputs = model(images)
            predictions = decode_multi_predictions(*outputs)
            for batch_index, prediction in enumerate(predictions):
                sample = samples[offset + batch_index]
                true_classes = classes[batch_index][valid[batch_index]]
                true_boxes = boxes[batch_index][valid[batch_index]]
                pairs = matched_pairs(
                    prediction["classes"], prediction["boxes"], true_classes, true_boxes
                )
                true_count, predicted_count, tp = len(true_boxes), len(prediction["boxes"]), len(pairs)
                fp, fn = predicted_count - tp, true_count - tp
                true_by_class.update(int(value) for value in true_classes)
                predicted_by_class.update(int(value) for value in prediction["classes"])
                matched_by_class.update(int(true_classes[t]) for _, t, _ in pairs)
                pair_ious = [pair[2] for pair in pairs]
                matched_ious.extend(pair_ious)
                group = grouped_metrics[true_count]
                group["images"] += 1
                group["tp"] += tp
                group["fp"] += fp
                group["fn"] += fn
                group["count_correct"] += int(true_count == predicted_count)
                group["exact"] += int(tp == true_count and fp == 0 and fn == 0)
                lighting_group = lighting_metrics[str(sample["lighting_profile"])]
                lighting_group["images"] += 1
                lighting_group["tp"] += tp
                lighting_group["fp"] += fp
                lighting_group["fn"] += fn
                lighting_group["count_correct"] += int(true_count == predicted_count)
                lighting_group["exact"] += int(tp == true_count and fp == 0 and fn == 0)
                predicted_payload = [
                    {
                        "class_id": int(prediction["classes"][index]) + 1,
                        "confidence": float(prediction["scores"][index]),
                        "objectness": float(prediction["objectness"][index]),
                        "box": box_to_source(prediction["boxes"][index].detach().cpu().numpy()),
                    }
                    for index in range(predicted_count)
                ]
                image_rows.append(
                    {
                        "image": Path(sample["image"]).name,
                        "true_count": true_count,
                        "predicted_count": predicted_count,
                        "true_positive": tp,
                        "false_positive": fp,
                        "false_negative": fn,
                        "mean_matched_iou": float(np.mean(pair_ious)) if pair_ious else 0.0,
                        "exact": int(tp == true_count and fp == 0 and fn == 0),
                        "variant": sample["variant"],
                        "lighting_profile": sample["lighting_profile"],
                        "predictions_json": json.dumps(predicted_payload, ensure_ascii=False),
                    }
                )
            offset += images.shape[0]

    total_tp = sum(row["true_positive"] for row in image_rows)
    total_fp = sum(row["false_positive"] for row in image_rows)
    total_fn = sum(row["false_negative"] for row in image_rows)
    precision = total_tp / (total_tp + total_fp)
    recall = total_tp / (total_tp + total_fn)
    per_class = {}
    for class_index, class_name in enumerate(class_names):
        tp = matched_by_class[class_index]
        per_class[class_name] = {
            "true_objects": true_by_class[class_index],
            "predicted_objects": predicted_by_class[class_index],
            "matched_objects": tp,
            "precision": tp / max(1, predicted_by_class[class_index]),
            "recall": tp / max(1, true_by_class[class_index]),
        }
    by_object_count = {}
    for count, values in sorted(grouped_metrics.items()):
        group_precision = values["tp"] / max(1, values["tp"] + values["fp"])
        group_recall = values["tp"] / max(1, values["tp"] + values["fn"])
        by_object_count[str(count)] = {
            "images": values["images"],
            "precision": group_precision,
            "recall": group_recall,
            "count_accuracy": values["count_correct"] / values["images"],
            "exact_image_accuracy": values["exact"] / values["images"],
        }
    by_lighting_profile = {}
    for profile, values in sorted(lighting_metrics.items()):
        profile_precision = values["tp"] / max(1, values["tp"] + values["fp"])
        profile_recall = values["tp"] / max(1, values["tp"] + values["fn"])
        by_lighting_profile[profile] = {
            "images": values["images"],
            "precision": profile_precision,
            "recall": profile_recall,
            "f1": 2 * profile_precision * profile_recall / max(1e-9, profile_precision + profile_recall),
            "count_accuracy": values["count_correct"] / values["images"],
            "exact_image_accuracy": values["exact"] / values["images"],
        }
    report = {
        "checkpoint_epoch": checkpoint["epoch"],
        "test_images": len(image_rows),
        "true_objects": total_tp + total_fn,
        "predicted_objects": total_tp + total_fp,
        "true_positive": total_tp,
        "false_positive": total_fp,
        "false_negative": total_fn,
        "precision": precision,
        "recall": recall,
        "f1": 2 * precision * recall / (precision + recall),
        "mean_matched_iou": float(np.mean(matched_ious)),
        "count_accuracy": float(np.mean([row["true_count"] == row["predicted_count"] for row in image_rows])),
        "exact_image_accuracy": float(np.mean([row["exact"] for row in image_rows])),
        "per_class": per_class,
        "by_true_object_count": by_object_count,
        "by_lighting_profile": by_lighting_profile,
    }
    (args.output_dir / "test_report.json").write_text(
        json.dumps(report, indent=2), encoding="utf-8"
    )
    with (args.output_dir / "test_predictions.csv").open("w", newline="", encoding="utf-8") as file:
        writer = csv.DictWriter(file, fieldnames=list(image_rows[0]))
        writer.writeheader()
        writer.writerows(image_rows)

    failures = [row for row in image_rows if not row["exact"]]
    rng = random.Random(20260805)
    remaining = [row for row in image_rows if row["exact"]]
    selected = failures[:20] + rng.sample(remaining, 40 - min(20, len(failures)))
    sheet = Image.new("RGB", (5 * 320, 8 * 260), "white")
    sheet_draw = ImageDraw.Draw(sheet)
    sample_by_name = {Path(sample["image"]).name: sample for sample in samples}
    for index, row in enumerate(selected):
        sample = sample_by_name[str(row["image"])]
        with Image.open(Path(sample["image"])) as opened:
            image = opened.convert("RGB")
        draw = ImageDraw.Draw(image)
        for box in np.asarray(sample["boxes"], dtype=np.int32):
            draw.rectangle(tuple(int(value) for value in box), outline="lime", width=2)
        predictions = json.loads(str(row["predictions_json"]))
        for prediction in predictions:
            draw.rectangle(tuple(prediction["box"]), outline="red", width=2)
            draw.text(
                (prediction["box"][0], max(0, prediction["box"][1] - 10)),
                f"P{prediction['class_id']} {prediction['confidence']:.2f}",
                fill="red",
            )
        x, y = index % 5 * 320, index // 5 * 260
        sheet.paste(image, (x, y))
        sheet_draw.text(
            (x + 3, y + 242),
            f"{row['image']} T{row['true_count']} P{row['predicted_count']} exact={row['exact']}",
            fill="black",
        )
    sheet.save(args.output_dir / "test_preview.jpg", quality=92)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
