import json
from pathlib import Path
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont
import torch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "model"))
from network import decode, integer_forward
from train_dataset import CameraDataset


def main():
    torch.set_num_threads(4)
    model = json.loads((ROOT / "model/gesture/model.json").read_text())
    dataset = CameraDataset(ROOT / "model/checkpoints/gesture_dataset", "val", model["classes"][3:12], "hand")
    with np.load(ROOT / "model/gesture/micro_yolo.npz", allow_pickle=False) as contents:
        arrays = dict(contents)
    selected = [next(index for index, sample in enumerate(dataset.samples) if sample[2] and sample[2][0] == category) for category in range(3, 12)]
    canvas = Image.new("RGB", (1020, 760), "#162030")
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.truetype("C:/Windows/Fonts/consola.ttf", 14)
    draw.text((12, 8), "GESTURE 1-9 / exact INT8 software / held-out photos / EXPERIMENTAL", font=font, fill="white")
    draw.text((12, 29), "First example per class; failures retained; NOT a board image", font=font, fill="#bfcddd")
    reports = []
    for panel, index in enumerate(selected):
        pixels, target = dataset[index]
        values = np.rint(pixels[0].numpy() * 128).astype(np.uint8)
        output = integer_forward(values, arrays)
        prediction = decode(output, model["enabled_classes"], model["object_threshold"])
        cell = output.reshape(16, 27)[int(np.argmax(output[:, :, 0]))]
        scores = sorted((int(cell[5 + category]) for category in model["enabled_classes"]), reverse=True)
        accepted = prediction is not None and scores[0] - scores[1] >= model["class_margin_threshold"]
        left, top = 12 + panel % 3 * 340, 62 + panel // 3 * 230
        with Image.open(dataset.samples[index][0]) as source:
            canvas.paste(source.convert("RGB").resize((160, 120)), (left, top))
        mask = Image.fromarray(255 - 2 * values).convert("RGB").resize((128, 128), Image.Resampling.NEAREST)
        canvas.paste(mask, (left + 170, top))
        if prediction:
            box = prediction["box"]
            draw.rectangle((left + 170 + box[0] * 2, top + box[1] * 2,
                            left + 170 + box[2] * 2, top + box[3] * 2), outline="#ff3030", width=2)
        result = "HAND " + str(prediction["category"] - 2) if accepted else "REJECT"
        correct = accepted and prediction["category"] == int(target["category"])
        draw.text((left, top + 138), f"GT HAND {panel + 1} / {result}", font=font, fill="#82e39d" if correct else "#ff9999")
        draw.text((left, top + 161), f"Q7 {int(cell[0])} M {scores[0] - scores[1]}", font=font, fill="#bfcddd")
        reports.append(dict(ground_truth=panel + 1, sample_index=index, prediction=prediction, quality_accepted=accepted, correct=bool(correct)))
    destination = ROOT / "validation/gesture_examples.png"
    canvas.save(destination)
    destination.with_suffix(".json").write_text(json.dumps(dict(selection="first held-out positive per class; no success filtering", examples=reports), indent=2) + "\n", encoding="utf-8")
    print(destination)


if __name__ == "__main__":
    main()
