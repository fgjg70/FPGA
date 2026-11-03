from __future__ import annotations

import argparse
import csv
import json
import random
import time
from pathlib import Path

import numpy as np
import torch
from torch.optim import AdamW
from torch.optim.lr_scheduler import CosineAnnealingLR
from torch.utils.data import DataLoader

from .config import PROJECT_ROOT
from .mobilenet_anchor_free import MobileNetNutAnchorFree
from .multi_anchor_free import decode_multi_predictions, multi_anchor_free_loss
from .multi_dataset import MultiNutDataset, read_multi_split


DATASET_DIR = PROJECT_ROOT / "nut_dataset_multi_7to1"
DEFAULT_INIT = (
    PROJECT_ROOT
    / "runs"
    / "mobilenet_nut_anchor_free_dark_walnut_finetune"
    / "best_model.pt"
)
CLASS_NAMES = ["chickpea", "cashew", "almond", "walnut"]


def seed_everything(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)


def pairwise_iou(boxes_a: torch.Tensor, boxes_b: torch.Tensor) -> torch.Tensor:
    top_left = torch.maximum(boxes_a[:, None, :2], boxes_b[None, :, :2])
    bottom_right = torch.minimum(boxes_a[:, None, 2:], boxes_b[None, :, 2:])
    intersection = (bottom_right - top_left).clamp(min=0).prod(dim=2)
    area_a = (boxes_a[:, 2:] - boxes_a[:, :2]).clamp(min=0).prod(dim=1)
    area_b = (boxes_b[:, 2:] - boxes_b[:, :2]).clamp(min=0).prod(dim=1)
    return intersection / (area_a[:, None] + area_b[None, :] - intersection).clamp(min=1e-7)


def match_detections(
    prediction: dict[str, torch.Tensor],
    true_classes: torch.Tensor,
    true_boxes: torch.Tensor,
    iou_threshold: float = 0.5,
) -> tuple[int, int, int, list[float]]:
    predicted_classes = prediction["classes"]
    predicted_boxes = prediction["boxes"]
    if len(predicted_boxes) == 0:
        return 0, 0, len(true_boxes), []
    ious = pairwise_iou(predicted_boxes, true_boxes)
    class_match = predicted_classes[:, None].eq(true_classes[None, :])
    candidate = ious.masked_fill(~class_match, -1.0)
    matched_predicted: set[int] = set()
    matched_true: set[int] = set()
    matched_ious: list[float] = []
    while candidate.numel() and float(candidate.max()) >= iou_threshold:
        flat = int(candidate.argmax())
        predicted_index = flat // candidate.shape[1]
        true_index = flat % candidate.shape[1]
        matched_predicted.add(predicted_index)
        matched_true.add(true_index)
        matched_ious.append(float(candidate[predicted_index, true_index]))
        candidate[predicted_index, :] = -1.0
        candidate[:, true_index] = -1.0
    true_positive = len(matched_true)
    return (
        true_positive,
        len(predicted_boxes) - true_positive,
        len(true_boxes) - true_positive,
        matched_ious,
    )


@torch.no_grad()
def evaluate(
    model: MobileNetNutAnchorFree,
    loader: DataLoader,
    device: torch.device,
) -> dict[str, float]:
    model.eval()
    loss_sum = 0.0
    image_count = 0
    true_positive = false_positive = false_negative = 0
    matched_ious: list[float] = []
    exact_images = count_correct = 0
    for images, classes, boxes, valid in loader:
        images = images.to(device)
        classes, boxes, valid = classes.to(device), boxes.to(device), valid.to(device)
        objectness, class_maps, box_maps = model(images)
        loss, _ = multi_anchor_free_loss(
            objectness, class_maps, box_maps, classes, boxes, valid
        )
        predictions = decode_multi_predictions(objectness, class_maps, box_maps)
        loss_sum += float(loss) * images.shape[0]
        image_count += images.shape[0]
        for batch_index, prediction in enumerate(predictions):
            true_classes = classes[batch_index][valid[batch_index]]
            true_boxes = boxes[batch_index][valid[batch_index]]
            tp, fp, fn, ious = match_detections(
                prediction, true_classes, true_boxes
            )
            true_positive += tp
            false_positive += fp
            false_negative += fn
            matched_ious.extend(ious)
            predicted_count = len(prediction["boxes"])
            true_count = len(true_boxes)
            count_correct += int(predicted_count == true_count)
            exact_images += int(tp == true_count and fp == 0 and fn == 0)
    precision = true_positive / max(1, true_positive + false_positive)
    recall = true_positive / max(1, true_positive + false_negative)
    f1 = 2 * precision * recall / max(1e-9, precision + recall)
    return {
        "test_loss": loss_sum / image_count,
        "test_precision": precision,
        "test_recall": recall,
        "test_f1": f1,
        "test_mean_iou": float(np.mean(matched_ious)) if matched_ious else 0.0,
        "test_count_accuracy": count_correct / image_count,
        "test_exact_image_accuracy": exact_images / image_count,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Fine-tune the dense detector for 1-4 nuts")
    parser.add_argument("--epochs", type=int, default=15)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--learning-rate", type=float, default=3e-4)
    parser.add_argument("--patience", type=int, default=5)
    parser.add_argument("--init-checkpoint", type=Path, default=DEFAULT_INIT)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=PROJECT_ROOT / "runs" / "mobilenet_nut_multi_anchor_free",
    )
    args = parser.parse_args()
    seed = 20260805
    seed_everything(seed)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    train_samples = read_multi_split(DATASET_DIR, "train")
    test_samples = read_multi_split(DATASET_DIR, "test")
    train_dataset = MultiNutDataset(train_samples, training=True, seed=seed)
    test_dataset = MultiNutDataset(test_samples, training=False, seed=seed)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    train_loader = DataLoader(
        train_dataset,
        batch_size=args.batch_size,
        shuffle=True,
        num_workers=0,
        pin_memory=device.type == "cuda",
    )
    test_loader = DataLoader(
        test_dataset, batch_size=args.batch_size, shuffle=False, num_workers=0
    )

    model = MobileNetNutAnchorFree(num_classes=4).to(device)
    checkpoint = torch.load(args.init_checkpoint, map_location=device, weights_only=False)
    model.load_state_dict(checkpoint["model"] if "model" in checkpoint else checkpoint)
    parameter_count = sum(parameter.numel() for parameter in model.parameters())
    optimizer = AdamW(model.parameters(), lr=args.learning_rate, weight_decay=2e-4)
    scheduler = CosineAnnealingLR(optimizer, T_max=args.epochs, eta_min=1e-5)
    config = {
        "dataset_dir": str(DATASET_DIR),
        "train_images": len(train_dataset),
        "test_images": len(test_dataset),
        "epochs": args.epochs,
        "batch_size": args.batch_size,
        "learning_rate": args.learning_rate,
        "patience": args.patience,
        "seed": seed,
        "class_names": CLASS_NAMES,
        "max_detections": 4,
        "initialized_from": str(args.init_checkpoint.resolve()),
        "initialized_checkpoint_epoch": checkpoint.get("epoch"),
        "model": "unchanged MobileNetV2 backbone + FPN + dense 56x56 anchor-free head",
        "decode": "3x3 local peaks + confidence Top-K + class-aware NMS + Top-4",
    }
    (args.output_dir / "config.json").write_text(
        json.dumps(config, indent=2), encoding="utf-8"
    )
    print(
        f"device={device} train={len(train_dataset)} test={len(test_dataset)} "
        f"parameters={parameter_count:,}",
        flush=True,
    )

    history: list[dict[str, float | int]] = []
    best_score = -1.0
    epochs_without_improvement = 0
    start_time = time.time()
    for epoch in range(1, args.epochs + 1):
        epoch_start = time.time()
        train_dataset.set_epoch(epoch)
        model.train()
        train_loss_sum = 0.0
        train_count = 0
        for images, classes, boxes, valid in train_loader:
            images = images.to(device)
            classes, boxes, valid = classes.to(device), boxes.to(device), valid.to(device)
            optimizer.zero_grad(set_to_none=True)
            objectness, class_maps, box_maps = model(images)
            loss, _ = multi_anchor_free_loss(
                objectness, class_maps, box_maps, classes, boxes, valid
            )
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 5.0)
            optimizer.step()
            train_loss_sum += float(loss.detach()) * images.shape[0]
            train_count += images.shape[0]
        scheduler.step()
        metrics = evaluate(model, test_loader, device)
        row: dict[str, float | int] = {
            "epoch": epoch,
            "train_loss": train_loss_sum / train_count,
            "learning_rate": optimizer.param_groups[0]["lr"],
            "epoch_seconds": time.time() - epoch_start,
            **metrics,
        }
        history.append(row)
        score = metrics["test_f1"] + metrics["test_mean_iou"]
        if score > best_score + 1e-4:
            best_score = score
            epochs_without_improvement = 0
            torch.save(
                {
                    "model": model.state_dict(),
                    "config": config,
                    "class_names": CLASS_NAMES,
                    "epoch": epoch,
                    "metrics": metrics,
                    "parameter_count": parameter_count,
                    "head": "multi_anchor_free_56x56_top4",
                },
                args.output_dir / "best_model.pt",
            )
        else:
            epochs_without_improvement += 1
        print(
            f"epoch={epoch:03d} train={row['train_loss']:.4f} "
            f"test={metrics['test_loss']:.4f} P={metrics['test_precision']:.4f} "
            f"R={metrics['test_recall']:.4f} F1={metrics['test_f1']:.4f} "
            f"mIoU={metrics['test_mean_iou']:.4f} "
            f"count={metrics['test_count_accuracy']:.4f} "
            f"exact={metrics['test_exact_image_accuracy']:.4f} "
            f"seconds={row['epoch_seconds']:.1f}",
            flush=True,
        )
        if epochs_without_improvement >= args.patience:
            print(f"early stopping at epoch {epoch}", flush=True)
            break

    with (args.output_dir / "history.csv").open("w", newline="", encoding="utf-8") as file:
        writer = csv.DictWriter(file, fieldnames=list(history[0]))
        writer.writeheader()
        writer.writerows(history)
    summary = {
        "parameter_count": parameter_count,
        "fp32_parameter_size_mib": parameter_count * 4 / 1024**2,
        "int8_parameter_size_mib": parameter_count / 1024**2,
        "best_score": best_score,
        "epochs_completed": len(history),
        "elapsed_seconds": time.time() - start_time,
        "best_checkpoint": str(args.output_dir / "best_model.pt"),
    }
    (args.output_dir / "training_summary.json").write_text(
        json.dumps(summary, indent=2), encoding="utf-8"
    )
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == "__main__":
    main()
