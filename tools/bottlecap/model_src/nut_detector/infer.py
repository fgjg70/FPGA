from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import onnxruntime as ort
from PIL import Image, ImageDraw

from .config import CLASS_NAMES, PROJECT_ROOT


def preprocess(image: Image.Image) -> np.ndarray:
    image = image.convert("RGB").resize((224, 168), Image.Resampling.BILINEAR)
    array = np.asarray(image)
    array = np.pad(array, ((28, 28), (0, 0), (0, 0)), mode="edge")
    array = array.astype(np.float32) / 127.5 - 1.0
    return np.transpose(array, (2, 0, 1))[None]


def model_box_to_source(box: np.ndarray) -> tuple[int, int, int, int]:
    # Undo 224x168 + 28-row edge padding, then map back to 320x240.
    x1, y1, x2, y2 = box * 223.0
    x1 = x1 * 320.0 / 224.0
    x2 = x2 * 320.0 / 224.0
    y1 = (y1 - 28.0) * 240.0 / 168.0
    y2 = (y2 - 28.0) * 240.0 / 168.0
    return (
        int(np.clip(round(x1), 0, 319)),
        int(np.clip(round(y1), 0, 239)),
        int(np.clip(round(x2), 0, 319)),
        int(np.clip(round(y2), 0, 239)),
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Run one ONNX nut detection")
    parser.add_argument("image", type=Path)
    parser.add_argument(
        "--model",
        type=Path,
        default=PROJECT_ROOT / "runs" / "tiny_nut_fpn" / "tiny_nut_fpn.onnx",
    )
    parser.add_argument("--output", type=Path, default=Path("prediction.jpg"))
    args = parser.parse_args()

    with Image.open(args.image) as source:
        image = source.convert("RGB")
    if image.size != (320, 240):
        raise ValueError(f"Expected a 320x240 image, received {image.size}")
    session = ort.InferenceSession(str(args.model), providers=["CPUExecutionProvider"])
    probabilities, normalized_box = session.run(None, {"image": preprocess(image)})
    class_index = int(probabilities[0].argmax())
    confidence = float(probabilities[0, class_index])
    box = model_box_to_source(normalized_box[0])

    preview = image.copy()
    draw = ImageDraw.Draw(preview)
    draw.rectangle(box, outline="lime", width=2)
    draw.text((box[0], max(0, box[1] - 14)), f"{CLASS_NAMES[class_index]} {confidence:.3f}", fill="lime")
    preview.save(args.output)
    print(
        {
            "class_id": class_index + 1,
            "class_name": CLASS_NAMES[class_index],
            "confidence": confidence,
            "x_min": box[0],
            "y_min": box[1],
            "x_max": box[2],
            "y_max": box[3],
        }
    )


if __name__ == "__main__":
    main()

