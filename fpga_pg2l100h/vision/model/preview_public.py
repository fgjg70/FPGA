import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
import torch

from network import CLASSES, decode, integer_forward
from train import ROOT
from train_dataset import CameraDataset


def main():
    parser = argparse.ArgumentParser(description="Render fixed public validation examples using actual integer model outputs")
    parser.add_argument("--dataset", type=Path, default=ROOT / "model/checkpoints/public12_dataset")
    parser.add_argument("--model", type=Path, default=ROOT / "model")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/public_validation_examples.png")
    args = parser.parse_args()
    torch.set_num_threads(4)
    metadata = json.loads((args.model / "model.json").read_text())
    names = json.loads((args.dataset / "classes.json").read_text())
    dataset = CameraDataset(args.dataset, "val", names)
    indices = [next(index for index, sample in enumerate(dataset.samples) if sample[2] is not None and sample[2][0] == category) for category in range(12)]
    inputs = np.stack([np.rint(dataset[index][0][0].numpy() * 128).astype(np.uint8) for index in indices])
    with np.load(args.model / "micro_yolo.npz", allow_pickle=False) as contents:
        outputs = integer_forward(inputs, dict(contents))
    canvas = Image.new("RGB", (1280, 40 + 3 * 296), "white")
    draw = ImageDraw.Draw(canvas)
    draw.text((8, 5), "EXACT INTEGER REFERENCE / PUBLIC VALIDATION / NOT BOARD CAPTURE", fill="black")
    draw.text((8, 20), "Fixed first sample per class. Green: annotation (gestures: weak patch rectangle). Red: prediction.", fill="black")
    results = []
    for category, (index, output) in enumerate(zip(indices, outputs)):
        panel_left = category % 4 * 320
        panel_top = 40 + category // 4 * 296
        with Image.open(dataset.samples[index][0]) as image:
            canvas.paste(image.convert("RGB").resize((320, 240)), (panel_left, panel_top + 28))
        candidate = decode(output, metadata["enabled_classes"], metadata["object_threshold"])
        results.append(dict(expected=CLASSES[category], prediction=candidate, source=str(dataset.samples[index][0])))
        draw.text((panel_left + 4, panel_top), "EXPECTED: " + CLASSES[category].upper(), fill="black")
        predicted = candidate["name"].upper() if candidate else "NO TARGET"
        draw.text((panel_left + 4, panel_top + 14), "PREDICTED: " + predicted,
                  fill="darkgreen" if candidate and candidate["category"] == category else "red")
        boxes = [(dataset[index][1]["box"], "lime")]
        if candidate:
            boxes.append((candidate["box"], "red"))
        for box, color in boxes:
            left, top, right, bottom = map(float, box)
            rectangle = [panel_left + max(0, min(319, 32 + left * 4)), panel_top + 28 + max(0, min(239, top * 4 - 8)),
                         panel_left + max(0, min(319, 32 + right * 4)), panel_top + 28 + max(0, min(239, bottom * 4 - 8))]
            draw.rectangle(rectangle, outline=color, width=2)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(args.output)
    args.output.with_suffix(".json").write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    print(args.output)


if __name__ == "__main__":
    main()
