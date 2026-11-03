from __future__ import annotations

import argparse
import csv
import json
import random
from pathlib import Path

import numpy as np
import torch
from PIL import Image, ImageDraw
from torch.utils.data import DataLoader

from .anchor_free import decode_predictions
from .config import PROJECT_ROOT
from .dataset import NutDataset, read_fixed_split
from .losses import aligned_iou
from .mobilenet_anchor_free import MobileNetNutAnchorFree


CLASS_NAMES = ["chickpea", "cashew", "almond", "walnut"]


def box_to_source(box: np.ndarray) -> tuple[int, int, int, int]:
    x1, y1, x2, y2 = box * 223.0
    return (
        int(np.clip(round(x1 * 320 / 224), 0, 319)),
        int(np.clip(round((y1 - 28) * 240 / 168), 0, 239)),
        int(np.clip(round(x2 * 320 / 224), 0, 319)),
        int(np.clip(round((y2 - 28) * 240 / 168), 0, 239)),
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Evaluate MobileNet anchor-free detector")
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
    args = parser.parse_args()
    dataset_dir = PROJECT_ROOT / "nut_dataset_balanced_7to1"
    run_dir = args.output_dir
    run_dir.mkdir(parents=True, exist_ok=True)
    samples = read_fixed_split(dataset_dir, "test")
    dataset = NutDataset(samples, range(len(samples)), training=False, seed=20260804)
    loader = DataLoader(dataset, batch_size=32, shuffle=False)
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    model = MobileNetNutAnchorFree(num_classes=4)
    model.load_state_dict(checkpoint["model"])
    model.eval()

    confusion = np.zeros((4, 4), dtype=np.int64)
    rows: list[dict[str, object]] = []
    offset = 0
    with torch.no_grad():
        for images, true_classes, true_boxes in loader:
            objectness, class_maps, box_maps = model(images)
            predicted_classes, confidence, predicted_boxes, _ = decode_predictions(
                objectness, class_maps, box_maps
            )
            objectness_probabilities = torch.sigmoid(objectness).flatten(1)
            flat_indices = objectness_probabilities.argmax(dim=1)
            selected_objectness = objectness_probabilities.gather(
                1, flat_indices[:, None]
            ).squeeze(1)
            selected_class_logits = class_maps.permute(0, 2, 3, 1).reshape(
                images.shape[0], -1, class_maps.shape[1]
            )[torch.arange(images.shape[0]), flat_indices]
            selected_class_probability = torch.softmax(
                selected_class_logits, dim=1
            ).amax(dim=1)
            ious = aligned_iou(predicted_boxes, true_boxes)
            for batch_index in range(images.shape[0]):
                sample = samples[offset + batch_index]
                true_class = int(true_classes[batch_index])
                predicted_class = int(predicted_classes[batch_index])
                confusion[true_class, predicted_class] += 1
                predicted_pixel_box = box_to_source(predicted_boxes[batch_index].numpy())
                rows.append(
                    {
                        "image": sample["image"].name,
                        "source_id": sample["source_id"],
                        "true_class_id": true_class + 1,
                        "predicted_class_id": predicted_class + 1,
                        "confidence": float(confidence[batch_index]),
                        "objectness": float(selected_objectness[batch_index]),
                        "class_probability": float(
                            selected_class_probability[batch_index]
                        ),
                        "iou": float(ious[batch_index]),
                        "predicted_x_min": predicted_pixel_box[0],
                        "predicted_y_min": predicted_pixel_box[1],
                        "predicted_x_max": predicted_pixel_box[2],
                        "predicted_y_max": predicted_pixel_box[3],
                    }
                )
            offset += images.shape[0]

    with (run_dir / "test_predictions.csv").open(
        "w", newline="", encoding="utf-8"
    ) as file:
        writer = csv.DictWriter(file, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)

    per_class = {}
    for class_index, class_name in enumerate(CLASS_NAMES):
        class_rows = [row for row in rows if row["true_class_id"] == class_index + 1]
        per_class[class_name] = {
            "images": len(class_rows),
            "accuracy": confusion[class_index, class_index] / len(class_rows),
            "mean_iou": float(np.mean([row["iou"] for row in class_rows])),
            "iou50": float(np.mean([row["iou"] >= 0.5 for row in class_rows])),
            "mean_confidence": float(
                np.mean([row["confidence"] for row in class_rows])
            ),
            "mean_objectness": float(
                np.mean([row["objectness"] for row in class_rows])
            ),
            "mean_class_probability": float(
                np.mean([row["class_probability"] for row in class_rows])
            ),
        }
    dark_walnut_rows = [
        row for row in rows if str(row["source_id"]).startswith("captures3/")
    ]
    dark_walnut = {
        "images": len(dark_walnut_rows),
        "accuracy": float(
            np.mean([row["predicted_class_id"] == 4 for row in dark_walnut_rows])
        ),
        "mean_iou": float(np.mean([row["iou"] for row in dark_walnut_rows])),
        "iou50": float(np.mean([row["iou"] >= 0.5 for row in dark_walnut_rows])),
        "mean_confidence": float(
            np.mean([row["confidence"] for row in dark_walnut_rows])
        ),
        "mean_objectness": float(
            np.mean([row["objectness"] for row in dark_walnut_rows])
        ),
        "mean_class_probability": float(
            np.mean([row["class_probability"] for row in dark_walnut_rows])
        ),
    }
    report = {
        "checkpoint_epoch": checkpoint["epoch"],
        "test_images": len(rows),
        "accuracy": float(np.trace(confusion) / confusion.sum()),
        "mean_iou": float(np.mean([row["iou"] for row in rows])),
        "iou50": float(np.mean([row["iou"] >= 0.5 for row in rows])),
        "mean_confidence": float(np.mean([row["confidence"] for row in rows])),
        "confusion_matrix_rows_true_columns_predicted": confusion.tolist(),
        "per_class": per_class,
        "dark_walnut_captures3": dark_walnut,
    }
    (run_dir / "test_report.json").write_text(
        json.dumps(report, indent=2), encoding="utf-8"
    )

    rng = random.Random(20260804)
    remaining_rows = [row for row in rows if row not in dark_walnut_rows]
    selected = dark_walnut_rows + rng.sample(remaining_rows, 40 - len(dark_walnut_rows))
    sheet = Image.new("RGB", (5 * 320, 8 * 260), "white")
    sheet_draw = ImageDraw.Draw(sheet)
    row_by_name = {row["image"]: row for row in rows}
    true_boxes = {
        sample["image"].name: tuple(int(value) for value in sample["bbox"])
        for sample in samples
    }
    for index, row in enumerate(selected):
        image_path = dataset_dir / "test" / str(row["image"])
        with Image.open(image_path) as source:
            image = source.convert("RGB")
        draw = ImageDraw.Draw(image)
        true_box = true_boxes[str(row["image"])]
        predicted_box = (
            int(row["predicted_x_min"]),
            int(row["predicted_y_min"]),
            int(row["predicted_x_max"]),
            int(row["predicted_y_max"]),
        )
        draw.rectangle(true_box, outline="lime", width=2)
        draw.rectangle(predicted_box, outline="red", width=2)
        x = (index % 5) * 320
        y = (index // 5) * 260
        sheet.paste(image, (x, y))
        sheet_draw.text(
            (x + 3, y + 242),
            f"{row['image']} T{row['true_class_id']} P{row['predicted_class_id']} "
            f"IoU={row['iou']:.2f}",
            fill="black",
        )
    sheet.save(run_dir / "test_preview.jpg", quality=92)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
