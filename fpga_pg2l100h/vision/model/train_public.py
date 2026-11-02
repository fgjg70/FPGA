import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import time

import numpy as np
import torch
from torch.nn import functional

from network import CLASSES, MicroYolo, decode, export_arrays, integer_forward
from train import ROOT, loss_value, write_model
from train_dataset import CameraDataset


def cached_dataset(dataset):
    samples = [dataset[index] for index in range(len(dataset))]
    pixels = torch.stack([sample[0] for sample in samples])
    targets = {name: torch.stack([torch.as_tensor(sample[1][name]) for sample in samples]) for name in samples[0][1]}
    return pixels, targets


def augment(pixels, targets, binary=False):
    batch = len(pixels)
    center_x = targets["column"].float() * 16 + targets["offset_x"].float() * 16
    center_y = targets["row"].float() * 16 + targets["offset_y"].float() * 16
    width = targets["width"].float() * 64
    height = targets["height"].float() * 64
    flip = (torch.rand(batch) < 0.5) & (targets["category"] < 12)
    center_x = torch.where(flip, 64 - center_x, center_x)
    shift_x = torch.randint(-5, 6, (batch,)).float()
    shift_y = torch.randint(-4, 5, (batch,)).float()
    shift_x = shift_x.maximum(1 + width / 2 - center_x).minimum(63 - width / 2 - center_x)
    shift_y = shift_y.maximum(2 + height / 2 - center_y).minimum(62 - height / 2 - center_y)
    transform = torch.zeros((batch, 2, 3))
    transform[:, 0, 0] = torch.where(flip, -1.0, 1.0)
    transform[:, 1, 1] = 1
    transform[:, 0, 2] = -transform[:, 0, 0] * shift_x / 32
    transform[:, 1, 2] = -shift_y / 32
    grid = functional.affine_grid(transform, pixels.shape, align_corners=False)
    pixels = functional.grid_sample(pixels, grid, align_corners=False)
    gain = 0.85 + torch.rand((batch, 1, 1, 1)) * 0.3
    pixels = pixels * gain + torch.randn_like(pixels) * 0.008
    pixels = pixels.clamp(0, 127 / 128).mul(128).round().div(128)
    if binary:
        pixels = (pixels > 0.45).float() * (127 / 128)
    pixels[:, :, :2] = 0
    pixels[:, :, 62:] = 0
    center_x += shift_x
    center_y += shift_y
    targets = {name: values.clone() for name, values in targets.items()}
    targets.update(column=(center_x // 16).long(), row=(center_y // 16).long(),
                   offset_x=center_x / 16 % 1, offset_y=center_y / 16 % 1)
    targets["box"] = torch.stack([center_x - width / 2, center_y - height / 2, center_x + width / 2, center_y + height / 2], 1)
    return pixels, targets


def evaluate(network, pixels, targets, enabled, class_margin=24):
    arrays = export_arrays(network)
    reports = {name: dict(samples=0, detections=0, correct_class=0, correct_class_and_iou50=0, oracle_cell_correct=0) for name in CLASSES}
    confusion = np.zeros((23, 23), dtype=np.int64)
    candidates = []
    gated = dict(correct=0, wrong=0, rejected=0, negative_accepted=0)
    for start in range(0, len(pixels), 32):
        inputs = np.rint(pixels[start:start + 32, 0].numpy() * 128).astype(np.uint8)
        outputs = integer_forward(inputs, arrays)
        for offset, output in enumerate(outputs):
            index = start + offset
            candidate = decode(output, enabled)
            candidates.append(candidate)
            present = bool(targets["present"][index])
            expected = int(targets["category"][index]) if present else 22
            predicted = candidate["category"] if candidate else 22
            confusion[expected, predicted] += 1
            selected = output.reshape(16, 27)[int(np.argmax(output[:, :, 0]))]
            logits = sorted((int(selected[5 + category]) for category in enabled), reverse=True)
            accepted = candidate is not None and logits[0] - logits[1] >= class_margin
            if present:
                gated["correct"] += int(accepted and predicted == expected)
                gated["wrong"] += int(accepted and predicted != expected)
                gated["rejected"] += int(not accepted)
            else:
                gated["negative_accepted"] += int(accepted)
            if not present:
                continue
            report = reports[CLASSES[expected]]
            report["samples"] += 1
            oracle = output[int(targets["row"][index]), int(targets["column"][index]), 5:]
            report["oracle_cell_correct"] += int(max(enabled, key=lambda category: int(oracle[category])) == expected)
            if candidate:
                report["detections"] += 1
                correct = candidate["category"] == expected
                report["correct_class"] += int(correct)
                actual_box = candidate["box"]
                target_box = targets["box"][index].tolist()
                intersection = max(0, min(actual_box[2], target_box[2]) - max(actual_box[0], target_box[0])) * max(0, min(actual_box[3], target_box[3]) - max(actual_box[1], target_box[1]))
                union = (actual_box[2] - actual_box[0]) * (actual_box[3] - actual_box[1]) + (target_box[2] - target_box[0]) * (target_box[3] - target_box[1]) - intersection
                report["correct_class_and_iou50"] += int(correct and intersection / max(union, 1e-9) >= 0.5)
    for report in reports.values():
        report["recall_iou50"] = report["correct_class_and_iou50"] / max(1, report["samples"])
    blank_samples = int(confusion[22].sum())
    metrics = dict(validation_samples=len(pixels), per_class=reports, confusion=confusion.tolist(), quality_gate=gated,
                   confusion_labels=CLASSES + ["no target"], blank_samples=blank_samples,
                   blank_false_positives=int(confusion[22, :22].sum()),
                   correct_class_and_iou50=sum(report["correct_class_and_iou50"] for report in reports.values()),
                   positive_samples=sum(report["samples"] for report in reports.values()),
                   mean_class_recall_iou50=float(np.mean([reports[CLASSES[category]]["recall_iou50"] for category in enabled])),
                   mean_requested_class_recall_iou50=float(np.mean([reports[name]["recall_iou50"] for name in CLASSES[:12]])))
    return metrics, arrays, candidates


def save_vectors(directory, pixels, arrays, candidates):
    directory.mkdir(parents=True, exist_ok=True)
    detected = sorted([index for index, candidate in enumerate(candidates) if candidate is not None],
                      key=lambda index: candidates[index]["objectness"], reverse=True)
    if not detected:
        raise RuntimeError("The candidate model produced no validation detections")
    selected = [0, detected[0]]
    selected += [index for index in detected if index not in selected][:6]
    while len(selected) < 8:
        selected.append(len(selected))
    predictions = []
    for sample, index in enumerate(selected):
        values = np.rint(pixels[index, 0].numpy() * 128).astype(np.uint8)
        output = integer_forward(values, arrays)
        (directory / f"input_{sample}.hex").write_text("".join(f"{value:02x}\n" for value in values.reshape(-1)), encoding="ascii")
        (directory / f"output_{sample}.hex").write_text("".join(f"{int(value) & 0xffffffff:08x}\n" for value in output.reshape(-1)), encoding="ascii")
        predictions.append(candidates[index])
    (directory / "reference_detections.json").write_text(json.dumps(predictions, indent=2) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description="Train and evaluate all 22 FPGA classes on cached public examples")
    parser.add_argument("--dataset", type=Path, default=ROOT / "model/checkpoints/public_dataset")
    parser.add_argument("--output", type=Path, default=ROOT / "model/candidates/public22")
    parser.add_argument("--steps", type=int, default=12000)
    parser.add_argument("--batch-size", type=int, default=96)
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--seed", type=int, default=2026)
    parser.add_argument("--init", type=Path, default=ROOT / "model/micro_yolo.npz")
    parser.add_argument("--from-scratch", action="store_true")
    parser.add_argument("--requested-only", action="store_true")
    parser.add_argument("--gesture-only", action="store_true")
    parser.add_argument("--class-weight", type=float, default=0.3)
    parser.add_argument("--background-penalty", type=float, default=0.0)
    args = parser.parse_args()
    torch.set_num_threads(args.threads)
    torch.manual_seed(args.seed)
    names = json.loads((args.dataset / "classes.json").read_text())
    if args.gesture_only and args.requested_only:
        parser.error("Select only one class profile")
    expected_names = CLASSES[3:12] if args.gesture_only else CLASSES[:12] if args.requested_only else CLASSES
    if names != expected_names:
        raise ValueError("Dataset classes must match the selected fixed hardware class order")
    training = CameraDataset(args.dataset, "train", names, "hand" if args.gesture_only else "label")
    validation = CameraDataset(args.dataset, "val", names, "hand" if args.gesture_only else "label")
    if training.hashes & validation.hashes:
        raise ValueError("Identical image content occurs in both train and val")
    provenance = json.loads((args.dataset / "provenance.json").read_text())
    if provenance["source_group_overlap"]:
        raise ValueError("Source photographs overlap between train and val")
    print("Caching decoded camera preprocessing in memory", flush=True)
    training_pixels, training_targets = cached_dataset(training)
    validation_pixels, validation_targets = cached_dataset(validation)
    filtered_positive = 0
    if args.gesture_only:
        keep = ~training_targets["present"] | ((training_pixels > 0).flatten(1).sum(1) >= 32)
        filtered_positive = int((~keep).sum())
        training_pixels = training_pixels[keep]
        training_targets = {name: values[keep] for name, values in training_targets.items()}
    groups = torch.where(training_targets["present"], training_targets["category"], 22)
    counts = Counter(groups.tolist())
    weights = torch.tensor([(3 if int(group) == 22 else 1) / counts[int(group)] for group in groups])
    network = MicroYolo()
    if not args.from_scratch and args.init and args.init.exists():
        with np.load(args.init, allow_pickle=False) as arrays, torch.no_grad():
            for index, layer in enumerate(network.layers):
                scale = 2 ** int(arrays[f"shift_{index}"])
                layer.weight.copy_(torch.from_numpy(arrays[f"weight_{index}"].astype(np.float32) / scale))
                layer.bias.copy_(torch.from_numpy(arrays[f"bias_{index}"].astype(np.float32) / (scale * 128)))
    optimizer = torch.optim.Adam(network.parameters(), lr=0.001)
    started = time.time()
    for step in range(args.steps):
        indices = torch.multinomial(weights, args.batch_size, replacement=True)
        pixels, targets = augment(training_pixels[indices], {name: values[indices] for name, values in training_targets.items()}, binary=args.gesture_only)
        optimizer.zero_grad(set_to_none=True)
        output = network(pixels)
        loss = loss_value(output, targets, args.class_weight)
        background = ~targets["present"]
        if args.background_penalty and background.any():
            loss = loss + args.background_penalty * output[background, 0].flatten(1).amax(1).square().mean()
        if not torch.isfinite(loss):
            raise RuntimeError("Training loss is not finite")
        loss.backward()
        optimizer.step()
        if step + 1 == args.steps * 3 // 4:
            for group in optimizer.param_groups:
                group["lr"] = 0.00025
        if step % 250 == 0:
            print(json.dumps(dict(step=step + 1, loss=round(float(loss.detach()), 5), seconds=round(time.time() - started))), flush=True)
    print("Evaluating held-out source photos with exact integer arithmetic", flush=True)
    enabled = list(range(3, 12)) if args.gesture_only else list(range(len(expected_names)))
    metrics, arrays, candidates = evaluate(network, validation_pixels, validation_targets, enabled)
    metrics.update(seed=args.seed, steps=args.steps, elapsed_seconds=round(time.time() - started, 2), class_weight=args.class_weight,
                   background_penalty=args.background_penalty,
                   train_source=("Chinese gestures 1-9 with digit/background negatives; source-photo split" if args.gesture_only else "COCO image-ID split + Chinese gesture source-photo split" + (" + MNIST train" if not args.requested_only else "")),
                   validation_source="Held-out source groups" + (" and MNIST test" if not args.requested_only else "") + "; see dataset provenance",
                   evaluation_arithmetic="exact INT64 reference with INT8 weights and activations, signed right shift",
                   supported_domain="Experimental public-data prototype; gesture patch boxes are weak labels; physical camera untested",
                   deployment_status="experimental", class_margin_threshold=24, empty_threshold=40,
                   dataset_counts=provenance["counts"], limitations=provenance["limitations"],
                   dataset_provenance_sha256=hashlib.sha256((args.dataset / "provenance.json").read_bytes()).hexdigest(),
                   initialization_sha256=hashlib.sha256(args.init.read_bytes()).hexdigest() if not args.from_scratch and args.init and args.init.exists() else None)
    metrics["filtered_unusable_training_positive"] = filtered_positive
    write_model(network, metrics, enabled, args.output)
    if args.gesture_only:
        exported = json.loads((args.output / "model.json").read_text())
        exported["input_preprocessing"] = "RGB565 skin silhouette: R>50 G>25 B>10 R>G+5 R>B+15; foreground Q7=127; background and padding=0"
        (args.output / "model.json").write_text(json.dumps(exported, indent=2) + "\n", encoding="utf-8")
    save_vectors(args.output / "vectors", validation_pixels, arrays, candidates)
    print(json.dumps(metrics, indent=2), flush=True)


if __name__ == "__main__":
    main()
