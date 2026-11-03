from __future__ import annotations

import csv
import json
from pathlib import Path

import numpy as np
import onnxruntime as ort
from PIL import Image, ImageDraw

from .config import CLASS_NAMES, PROJECT_ROOT, TrainConfig
from .infer import model_box_to_source, preprocess


def pixel_iou(a: tuple[int, int, int, int], b: tuple[int, int, int, int]) -> float:
    ix1, iy1 = max(a[0], b[0]), max(a[1], b[1])
    ix2, iy2 = min(a[2], b[2]), min(a[3], b[3])
    intersection = max(0, ix2 - ix1 + 1) * max(0, iy2 - iy1 + 1)
    area_a = (a[2] - a[0] + 1) * (a[3] - a[1] + 1)
    area_b = (b[2] - b[0] + 1) * (b[3] - b[1] + 1)
    return intersection / (area_a + area_b - intersection + 1e-7)


def main() -> None:
    run_dir = PROJECT_ROOT / "runs" / "tiny_nut_fpn"
    dataset_dir = TrainConfig().dataset_dir
    split = json.loads((run_dir / "split.json").read_text(encoding="utf-8"))
    validation_names = set(split["validation"])
    records: dict[str, dict[str, str]] = {}
    with (dataset_dir / "annotations.csv").open(encoding="utf-8-sig") as file:
        for row in csv.DictReader(file):
            records[row["image"]] = row

    session = ort.InferenceSession(
        str(run_dir / "tiny_nut_fpn.onnx"), providers=["CPUExecutionProvider"]
    )
    confusion = np.zeros((4, 4), dtype=np.int64)
    rows: list[dict[str, object]] = []
    previews: list[tuple[str, Image.Image]] = []
    for image_name in sorted(validation_names):
        row = records[image_name]
        true_class = int(row["class_id"]) - 1
        true_box = tuple(int(row[key]) for key in ("x_min", "y_min", "x_max", "y_max"))
        with Image.open(dataset_dir / "images" / image_name) as source:
            image = source.convert("RGB")
        probabilities, normalized_box = session.run(None, {"image": preprocess(image)})
        predicted_class = int(probabilities[0].argmax())
        confidence = float(probabilities[0, predicted_class])
        predicted_box = model_box_to_source(normalized_box[0])
        iou = pixel_iou(predicted_box, true_box)
        confusion[true_class, predicted_class] += 1
        rows.append(
            {
                "image": image_name,
                "true_class": true_class + 1,
                "predicted_class": predicted_class + 1,
                "confidence": confidence,
                "iou": iou,
                "predicted_x_min": predicted_box[0],
                "predicted_y_min": predicted_box[1],
                "predicted_x_max": predicted_box[2],
                "predicted_y_max": predicted_box[3],
            }
        )
        preview = image.copy()
        draw = ImageDraw.Draw(preview)
        draw.rectangle(true_box, outline="lime", width=2)
        draw.rectangle(predicted_box, outline="red", width=2)
        draw.text(
            (4, 4),
            f"GT {true_class + 1}:{CLASS_NAMES[true_class]}  "
            f"P {predicted_class + 1}:{CLASS_NAMES[predicted_class]} {confidence:.2f}  "
            f"IoU {iou:.2f}",
            fill="white",
            stroke_width=2,
            stroke_fill="black",
        )
        previews.append((Path(image_name).stem, preview))

    with (run_dir / "validation_predictions.csv").open(
        "w", newline="", encoding="utf-8"
    ) as file:
        writer = csv.DictWriter(file, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)

    sheet = Image.new("RGB", (640, ((len(previews) + 1) // 2) * 264), "white")
    sheet_draw = ImageDraw.Draw(sheet)
    for index, (stem, preview) in enumerate(previews):
        x = (index % 2) * 320
        y = (index // 2) * 264
        sheet.paste(preview, (x, y))
        sheet_draw.text((x + 4, y + 244), stem, fill="black")
    sheet.save(run_dir / "validation_preview.jpg", quality=94)

    accuracy = float(np.trace(confusion) / confusion.sum())
    mean_iou = float(np.mean([float(row["iou"]) for row in rows]))
    report = {
        "validation_images": len(rows),
        "accuracy": accuracy,
        "mean_iou": mean_iou,
        "iou50": float(np.mean([float(row["iou"]) >= 0.5 for row in rows])),
        "confusion_matrix_rows_true_columns_predicted": confusion.tolist(),
    }
    (run_dir / "validation_report.json").write_text(
        json.dumps(report, indent=2), encoding="utf-8"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
