import argparse
import gzip
import hashlib
import json
from pathlib import Path
import time

import numpy as np
import torch
from torch.nn import functional

from network import CLASSES, LAYERS, MicroYolo, decode, export_arrays, integer_forward


ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT.parents[1] / "fpga_mes50hp/model/cache"


def mnist(split):
    prefix = "train" if split == "train" else "t10k"
    with gzip.open(CACHE / f"{prefix}-images-idx3-ubyte.gz", "rb") as source:
        images = np.frombuffer(source.read(), dtype=np.uint8, offset=16).copy().reshape(-1, 1, 28, 28)
    with gzip.open(CACHE / f"{prefix}-labels-idx1-ubyte.gz", "rb") as source:
        labels = np.frombuffer(source.read(), dtype=np.uint8, offset=8).copy().astype(np.int64)
    return torch.from_numpy(images).float() / 255, torch.from_numpy(labels)


def make_batch(images, labels, batch_size, generator, evaluation=False):
    selected = torch.randint(len(images), (batch_size,), generator=generator)
    size = torch.randint(20, 43, (batch_size,), generator=generator).float()
    center_x = 4 + size / 2 + torch.rand(batch_size, generator=generator) * (56 - size)
    center_y = 4 + size / 2 + torch.rand(batch_size, generator=generator) * (56 - size)
    theta = torch.zeros(batch_size, 2, 3)
    angle = (torch.rand(batch_size, generator=generator) - 0.5) * 0.35
    scale = 64 / size
    theta[:, 0, 0] = angle.cos() * scale
    theta[:, 0, 1] = -angle.sin() * scale
    theta[:, 1, 0] = angle.sin() * scale
    theta[:, 1, 1] = angle.cos() * scale
    translated_x = 1 - 2 * center_x / 64
    translated_y = 1 - 2 * center_y / 64
    theta[:, 0, 2] = translated_x * theta[:, 0, 0] + translated_y * theta[:, 0, 1]
    theta[:, 1, 2] = translated_x * theta[:, 1, 0] + translated_y * theta[:, 1, 1]
    grid = functional.affine_grid(theta, (batch_size, 1, 64, 64), align_corners=False)
    pixels = functional.grid_sample(images[selected], grid, align_corners=False)
    blank = torch.rand(batch_size, generator=generator) < 0.15
    pixels[blank] = 0
    pixels *= 0.6 + 0.4 * torch.rand(batch_size, 1, 1, 1, generator=generator)
    pixels += torch.rand(pixels.shape, generator=generator) * (0.025 if evaluation else 0.06)
    pixels[:, :, :2] = 0
    pixels[:, :, 62:] = 0
    pixels = torch.round(pixels.clamp(0, 127 / 128) * 128) / 128
    targets = dict(category=labels[selected] + 12, column=(center_x / 16).long(), row=(center_y / 16).long(),
                   offset_x=center_x / 16 % 1, offset_y=center_y / 16 % 1,
                   width=size / 64, height=size / 64, present=~blank,
                   box=torch.stack([center_x - size / 2, center_y - size / 2, center_x + size / 2, center_y + size / 2], 1))
    return pixels, targets


def loss_value(output, targets, class_weight=0.3):
    object_target = torch.zeros_like(output[:, 0])
    indices = torch.arange(len(output))
    present = targets["present"]
    object_target[indices[present], targets["row"][present], targets["column"][present]] = 1
    weights = 1 + 15 * object_target
    loss = (((output[:, 0] - object_target) ** 2) * weights).mean()
    selected = output[indices[present], :, targets["row"][present], targets["column"][present]]
    if len(selected):
        boxes = torch.stack([targets[name][present] for name in ["offset_x", "offset_y", "width", "height"]], 1).to(selected.dtype)
        loss = loss + 3 * functional.mse_loss(selected[:, 1:5], boxes)
        loss = loss + class_weight * functional.cross_entropy(selected[:, 5:], targets["category"][present])
    return loss


def write_model(network, metadata, enabled_classes=None, model_dir=None):
    arrays = export_arrays(network)
    weights = np.concatenate([arrays[f"weight_{index}"].transpose(0, 2, 3, 1).reshape(-1) for index in range(len(LAYERS))])
    biases = np.concatenate([arrays[f"bias_{index}"] for index in range(len(LAYERS))])
    model_dir = ROOT / "model" if model_dir is None else Path(model_dir)
    model_dir.mkdir(parents=True, exist_ok=True)
    np.savez(model_dir / "micro_yolo.npz", **arrays)
    for filename, values, count, digits in [("weights.hex", weights, 32768, 2), ("biases.hex", biases, 256, 8),
                                           ("shifts.hex", [int(arrays[f"shift_{index}"]) for index in range(6)], 6, 2)]:
        padded = list(values) + [0] * (count - len(values))
        (model_dir / filename).write_text("".join(f"{int(value) & ((1 << (4 * digits)) - 1):0{digits}x}\n" for value in padded), encoding="ascii")
    enabled = list(range(12, 22)) if enabled_classes is None else sorted(enabled_classes)
    metadata.update(classes=CLASSES, enabled_classes=enabled, input=[64, 64, 1], grid=[4, 4],
                    architecture=LAYERS, weight_bytes=len(weights), bias_bytes=4 * len(biases),
                    activation_bytes=16384, result_bytes=2048, object_threshold=72,
                    input_preprocessing="central 128x128 crop including four source padding rows at each side; two sampled padding rows at each side; inverted luminance / 2",
                    model_type="custom YOLO-style single-box-per-cell detector; not a stock YOLO checkpoint",
                    hardware_tested=False,
                    unsupported_classes=[name for index, name in enumerate(CLASSES) if index not in enabled])
    metadata.setdefault("supported_domain", "dark handwritten digits on a light plain background")
    metadata["sha256"] = {name: hashlib.sha256((model_dir / name).read_bytes()).hexdigest()
                          for name in ["micro_yolo.npz", "weights.hex", "biases.hex", "shifts.hex"]}
    (model_dir / "model.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    return arrays


def main():
    parser = argparse.ArgumentParser(description="Train an INT8 MicroYOLO digit detector on cached MNIST")
    parser.add_argument("--steps", type=int, default=2500)
    parser.add_argument("--batch-size", type=int, default=96)
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--seed", type=int, default=2026)
    args = parser.parse_args()
    torch.set_num_threads(args.threads)
    torch.manual_seed(args.seed)
    generator = torch.Generator().manual_seed(args.seed)
    training_images, training_labels = mnist("train")
    test_images, test_labels = mnist("test")
    network = MicroYolo()
    optimizer = torch.optim.Adam(network.parameters(), lr=0.002)
    started = time.time()
    for step in range(args.steps):
        pixels, targets = make_batch(training_images, training_labels, args.batch_size, generator)
        optimizer.zero_grad(set_to_none=True)
        loss = loss_value(network(pixels), targets)
        loss.backward()
        optimizer.step()
        if step == args.steps * 3 // 4:
            for group in optimizer.param_groups:
                group["lr"] = 0.0005
        if step % 100 == 0 or step + 1 == args.steps:
            print(json.dumps(dict(step=step + 1, loss=round(float(loss.detach()), 5), elapsed_seconds=round(time.time() - started))), flush=True)
    with torch.no_grad():
        pixels, targets = make_batch(test_images, test_labels, 512, torch.Generator().manual_seed(args.seed + 1), evaluation=True)
        arrays = export_arrays(network)
        predictions = integer_forward(np.rint(pixels[:, 0].numpy() * 128).astype(np.uint8), arrays)
        detected = 0
        correct = 0
        false_positive = 0
        localized_correct = 0
        iou_sum = 0.0
        for index, prediction in enumerate(predictions):
            candidate = decode(prediction, list(range(12, 22)))
            if targets["present"][index]:
                if candidate:
                    detected += 1
                    correct += int(candidate["category"] == int(targets["category"][index]))
                    predicted_box = candidate["box"]
                    target_box = targets["box"][index].tolist()
                    intersection = max(0, min(predicted_box[2], target_box[2]) - max(predicted_box[0], target_box[0])) * max(0, min(predicted_box[3], target_box[3]) - max(predicted_box[1], target_box[1]))
                    union = (predicted_box[2] - predicted_box[0]) * (predicted_box[3] - predicted_box[1]) + (target_box[2] - target_box[0]) * (target_box[3] - target_box[1]) - intersection
                    iou = intersection / max(union, 1e-9)
                    iou_sum += iou
                    localized_correct += int(iou >= 0.5 and candidate["category"] == int(targets["category"][index]))
            else:
                false_positive += int(candidate is not None)
    metadata = dict(seed=args.seed, steps=args.steps, train_source="MNIST train, synthetic placement/noise/blank augmentation",
                    validation_source="MNIST test with independent synthetic placement; no physical camera images",
                    validation_samples=len(pixels), positive_samples=int(targets["present"].sum()),
                    detections=detected, correct_class_detections=correct, blank_false_positives=false_positive,
                    correct_class_and_iou50=localized_correct, mean_iou_of_detections=iou_sum / max(1, detected),
                    evaluation_arithmetic="exact INT64 reference with INT8 weights and activations, signed right shift",
                    validation_precision_domain="synthetic digits only; not COCO or hand gestures",
                    elapsed_seconds=round(time.time() - started, 2))
    arrays = write_model(network, metadata)
    candidates = []
    validation = ROOT / "model/vectors"
    validation.mkdir(parents=True, exist_ok=True)
    for index in range(8):
        input_pixels = np.rint(pixels[index, 0].numpy() * 128).astype(np.uint8)
        output = integer_forward(input_pixels, arrays)
        (validation / f"input_{index}.hex").write_text("".join(f"{value:02x}\n" for value in input_pixels.reshape(-1)), encoding="ascii")
        (validation / f"output_{index}.hex").write_text("".join(f"{int(value) & 0xffffffff:08x}\n" for value in output.reshape(-1)), encoding="ascii")
        candidates.append(decode(output, list(range(12, 22))))
    (validation / "reference_detections.json").write_text(json.dumps(candidates, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(metadata, indent=2), flush=True)


if __name__ == "__main__":
    main()
