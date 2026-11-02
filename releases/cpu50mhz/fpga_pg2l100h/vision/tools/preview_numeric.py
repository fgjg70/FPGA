import json
from pathlib import Path
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont
import torch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "model"))
from network import decode, integer_forward
from train import mnist
from train_numeric import TEST_FONTS, batch, glyphs


def main():
    torch.set_num_threads(2)
    images, labels = mnist("test")
    printed, printed_labels, _ = glyphs(Path("C:/Windows/Fonts"), TEST_FONTS)
    negatives, _, _ = glyphs(Path("C:/Windows/Fonts"), TEST_FONTS, "AFKMNRTWXYZ+-=*")
    model = json.loads((ROOT / "model/model.json").read_text())
    pixels, targets = batch(images, labels, printed, printed_labels, negatives, 512, torch.Generator().manual_seed(model["seed"] + 1), evaluation=True, mode="printed")
    with np.load(ROOT / "model/micro_yolo.npz", allow_pickle=False) as archive:
        arrays = dict(archive)
    selected = [next(index for index in range(len(pixels)) if targets["present"][index] and int(targets["category"][index]) == digit + 12) for digit in range(10)]
    canvas = Image.new("RGB", (1100, 526), "#162030")
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.truetype("C:/Windows/Fonts/consola.ttf", 15)
    draw.text((12, 8), "NUMGUARD / exact INT8 software / synthetic validation / NOT a board photo", font=font, fill="white")
    reports = []
    for panel, index in enumerate(selected):
        values = np.rint(pixels[index, 0].numpy() * 128).astype(np.uint8)
        output = integer_forward(values, arrays)
        prediction = decode(output, list(range(12, 22)), model["object_threshold"])
        cell = output.reshape(16, 27)[int(np.argmax(output[:, :, 0]))]
        ranked = sorted(map(int, cell[17:27]), reverse=True)
        accepted = prediction is not None and ranked[0] - ranked[1] >= model["class_margin_threshold"]
        left = 10 + panel % 5 * 220
        top = 40 + panel // 5 * 240
        image = Image.fromarray(255 - 2 * values).convert("RGB").resize((192, 192), Image.Resampling.NEAREST)
        canvas.paste(image, (left, top))
        if prediction:
            box = prediction["box"]
            draw.rectangle((left + box[0] * 3, top + box[1] * 3, left + box[2] * 3, top + box[3] * 3), outline="#ff3030", width=2)
        result = f"DIGIT {prediction['category'] - 12}" if accepted else "REJECT"
        draw.text((left, top + 196), f"GT {panel} / {result}", font=font, fill="white")
        draw.text((left, top + 216), f"Q7 {int(cell[0])} M {ranked[0] - ranked[1]}", font=font, fill="#aabbd0")
        reports.append(dict(ground_truth=panel, sample_index=index, prediction=prediction, quality_accepted=accepted))
    destination = ROOT / "validation/numeric_examples.png"
    canvas.save(destination)
    destination.with_suffix(".json").write_text(json.dumps(dict(selection="first positive of each ground-truth class; no filtering by prediction success", domain="synthetic software validation", examples=reports), indent=2) + "\n", encoding="utf-8")
    print(destination)


if __name__ == "__main__":
    main()
