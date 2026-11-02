import argparse
import hashlib
import json
from pathlib import Path
import time

import numpy as np
from PIL import Image
import torch
from torch.utils.data import DataLoader, Dataset

from network import CLASSES, MicroYolo, decode, export_arrays, integer_forward
from train import ROOT, loss_value, write_model
from camera_preprocess import camera_input
from gesture_standard import HAND_NAMES, STANDARD_ID, bank_classes, require_standard


class CameraDataset(Dataset):
    def __init__(self, directory, split, names, mode="label"):
        class_names = bank_classes(CLASSES) if mode == "hand" and "hand 10" in names else CLASSES
        if mode == "hand" and "hand 10" in names:
            require_standard(directory)
        self.mode = mode
        self.directory = directory
        self.split = split
        self.samples = []
        self.class_counts = {name: 0 for name in names}
        self.hashes = set()
        paths = sorted(path for path in (directory / "images" / split).rglob("*") if path.suffix.lower() in [".jpg", ".jpeg", ".png", ".bmp"])
        for path in paths:
            annotation = directory / "labels" / split / path.relative_to(directory / "images" / split).with_suffix(".txt")
            rows = [line.split() for line in annotation.read_text().splitlines() if line.strip()]
            if len(rows) > 1:
                raise ValueError(f"This first model requires zero or one annotated target per image: {annotation}")
            target = None
            if rows:
                if len(rows[0]) != 5:
                    raise ValueError(f"Expected YOLO class/cx/cy/width/height: {annotation}")
                class_index = int(rows[0][0])
                center_x, center_y, width, height = map(float, rows[0][1:])
                if not 0 <= class_index < len(names) or not all(np.isfinite([center_x, center_y, width, height])) or width <= 0 or height <= 0:
                    raise ValueError(f"Invalid target: {annotation}")
                left = (center_x - width / 2) * 160
                right = (center_x + width / 2) * 160
                top = (center_y - height / 2) * 120
                bottom = (center_y + height / 2) * 120
                if left < 16 or right > 144 or top < 0 or bottom > 120:
                    raise ValueError(f"Target must be fully inside the central 128x120 camera region: {annotation}")
                category = class_names.index(names[class_index])
                target = [category, (center_x * 160 - 16) / 2, (center_y * 120 + 4) / 2, width * 80, height * 60]
                self.class_counts[names[class_index]] += 1
            self.samples.append((path, annotation, target))
            self.hashes.add(hashlib.sha256(path.read_bytes()).hexdigest())
        if not self.samples or any(count == 0 for count in self.class_counts.values()):
            raise ValueError(f"Each declared class requires actual {split} images; found {self.class_counts}")

    def __len__(self):
        return len(self.samples)

    def __getitem__(self, index):
        path, _, target = self.samples[index]
        relative = path.relative_to(self.directory / "images" / self.split)
        sidecar = self.directory / "metadata" / self.split / relative.with_suffix(".json")
        if sidecar.exists():
            metadata = json.loads(sidecar.read_text())
            if metadata.get("mode", "label") != self.mode:
                raise ValueError("Captured input mode does not match training preprocessing")
            if self.mode == "hand" and (self.directory / "gesture_standard.json").exists() and metadata.get("gesture_standard") != STANDARD_ID:
                raise ValueError("Captured hand input does not declare the selected gesture convention")
            data = (self.directory / metadata["input_file"]).read_bytes()
            if len(data) != 4096 or hashlib.sha256(data).hexdigest() != metadata["sha256"]:
                raise ValueError("Captured model input has changed")
            values = np.frombuffer(data, dtype=np.uint8).copy().reshape(64, 64)
        else:
            with Image.open(path) as image:
                rgb = np.asarray(image.convert("RGB").resize((160, 120), Image.Resampling.BILINEAR), dtype=np.uint16)
            values = camera_input(rgb, self.mode)
        category, center_x, center_y, width, height = target if target else [0, 32, 32, 0, 0]
        targets = dict(category=category, column=int(center_x // 16), row=int(center_y // 16),
                       offset_x=center_x / 16 % 1, offset_y=center_y / 16 % 1, width=width / 64, height=height / 64,
                       present=target is not None, box=np.array([center_x - width / 2, center_y - height / 2, center_x + width / 2, center_y + height / 2], dtype=np.float32))
        return torch.tensor(values, dtype=torch.float32).unsqueeze(0) / 128, targets


def evaluate(network, loader, enabled, class_names=None):
    arrays = export_arrays(network)
    report = dict(validation_samples=0, positive_samples=0, detections=0, correct_class_detections=0,
                  correct_class_and_iou50=0, blank_samples=0, blank_false_positives=0)
    for pixels, targets in loader:
        predictions = integer_forward(np.rint(pixels[:, 0].numpy() * 128).astype(np.uint8), arrays)
        for index, prediction in enumerate(predictions):
            candidate = decode(prediction, enabled, class_names=class_names)
            report["validation_samples"] += 1
            if not targets["present"][index]:
                report["blank_samples"] += 1
                report["blank_false_positives"] += int(candidate is not None)
                continue
            report["positive_samples"] += 1
            if candidate:
                report["detections"] += 1
                correct = candidate["category"] == int(targets["category"][index])
                report["correct_class_detections"] += int(correct)
                predicted_box = candidate["box"]
                expected_box = targets["box"][index].tolist()
                intersection = max(0, min(predicted_box[2], expected_box[2]) - max(predicted_box[0], expected_box[0])) * max(0, min(predicted_box[3], expected_box[3]) - max(predicted_box[1], expected_box[1]))
                union = (predicted_box[2] - predicted_box[0]) * (predicted_box[3] - predicted_box[1]) + (expected_box[2] - expected_box[0]) * (expected_box[3] - expected_box[1]) - intersection
                report["correct_class_and_iou50"] += int(correct and intersection / max(union, 1e-9) >= 0.5)
    return report


def main():
    parser = argparse.ArgumentParser(description="Train the same FPGA detector on annotated camera objects/gestures/digits")
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--steps", type=int, default=4000)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--seed", type=int, default=2026)
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--mode", choices=["label", "hand"], default="label")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    torch.set_num_threads(args.threads)
    torch.manual_seed(args.seed)
    names = json.loads((args.dataset / "classes.json").read_text())
    northern = args.mode == "hand" and names == HAND_NAMES
    class_names = bank_classes(CLASSES) if northern else CLASSES
    if not names or len(set(names)) != len(names) or any(name not in class_names for name in names):
        raise ValueError(f"Dataset classes must be unique names from {CLASSES}")
    if args.mode == "hand" and not northern and names != CLASSES[3:12]:
        raise ValueError("Hand training requires ordered legacy 1-9 or northern-reference 1-10 classes")
    if northern:
        require_standard(args.dataset)
    training = CameraDataset(args.dataset, "train", names, args.mode)
    validation = CameraDataset(args.dataset, "val", names, args.mode)
    if training.hashes & validation.hashes:
        raise ValueError("Identical image content occurs in both train and val splits")
    print(json.dumps(dict(train=training.class_counts, val=validation.class_counts), indent=2), flush=True)
    if args.validate_only:
        for dataset in [training, validation]:
            for index in range(len(dataset)):
                dataset[index]
        print("PASS dataset annotations, image decoding, class coverage and split separation")
        return
    network = MicroYolo()
    loader = DataLoader(training, batch_size=args.batch_size, shuffle=True)
    iterator = iter(loader)
    optimizer = torch.optim.Adam(network.parameters(), lr=0.002)
    started = time.time()
    for step in range(args.steps):
        try:
            pixels, targets = next(iterator)
        except StopIteration:
            iterator = iter(loader)
            pixels, targets = next(iterator)
        optimizer.zero_grad(set_to_none=True)
        loss = loss_value(network(pixels), targets)
        loss.backward()
        optimizer.step()
        if step == args.steps * 3 // 4:
            for group in optimizer.param_groups:
                group["lr"] = 0.0005
        if step % 100 == 0:
            print(json.dumps(dict(step=step + 1, loss=float(loss.detach()), seconds=round(time.time() - started))), flush=True)
    enabled = [class_names.index(name) for name in names]
    metrics = evaluate(network, DataLoader(validation, batch_size=32), enabled, class_names=class_names)
    metrics.update(seed=args.seed, steps=args.steps, supported_domain="User annotated camera dataset; inspect validation metrics before deployment",
                   train_source=str(args.dataset.resolve()), validation_source="Separate annotated val split, exact integer inference",
                   dataset_sha256={str(path.relative_to(args.dataset)): hashlib.sha256(path.read_bytes()).hexdigest()
                                   for dataset in [training, validation] for sample in dataset.samples for path in sample[:2]})
    if northern:
        metrics.update(gesture_standard=STANDARD_ID, gesture_numbers=list(range(1, 11)),
                       gesture_convention=json.loads((args.dataset / "gesture_standard.json").read_text(encoding="utf-8")))
    model_dir = args.output or (ROOT / "model/candidates/northern10" if northern else ROOT / "model/gesture" if args.mode == "hand" else ROOT / "model")
    arrays = write_model(network, metrics, enabled, model_dir, class_names=class_names)
    if args.mode == "hand":
        metadata = json.loads((model_dir / "model.json").read_text())
        metadata.update(class_margin_threshold=24, empty_threshold=40,
                        input_preprocessing="RGB565 skin silhouette: R>50 G>25 B>10 R>G+5 R>B+15; foreground Q7=127; background and padding=0")
        (model_dir / "model.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    output = model_dir / "vectors"
    output.mkdir(parents=True, exist_ok=True)
    candidates = []
    for index in range(min(8, len(validation))):
        pixels, _ = validation[index]
        values = np.rint(pixels[0].numpy() * 128).astype(np.uint8)
        prediction = integer_forward(values, arrays)
        (output / f"input_{index}.hex").write_text("".join(f"{value:02x}\n" for value in values.reshape(-1)), encoding="ascii")
        (output / f"output_{index}.hex").write_text("".join(f"{int(value) & 0xffffffff:08x}\n" for value in prediction.reshape(-1)), encoding="ascii")
        candidates.append(decode(prediction, enabled, class_names=class_names))
    (output / "reference_detections.json").write_text(json.dumps(candidates, indent=2) + "\n")
    print(json.dumps(metrics, indent=2), flush=True)


if __name__ == "__main__":
    main()
