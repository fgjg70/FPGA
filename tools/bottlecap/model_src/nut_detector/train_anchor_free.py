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

from .anchor_free import TinyNutAnchorFree, anchor_free_loss, decode_predictions
from .config import CLASS_NAMES, PROJECT_ROOT, TrainConfig
from .dataset import NutDataset, read_samples, save_split, stratified_split
from .losses import aligned_iou


def seed_everything(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)


@torch.no_grad()
def validate(
    model: TinyNutAnchorFree, loader: DataLoader, device: torch.device
) -> dict[str, float]:
    model.eval()
    total_loss = 0.0
    correct = 0
    iou_sum = 0.0
    iou50 = 0
    count = 0
    for images, classes, boxes in loader:
        images, classes, boxes = images.to(device), classes.to(device), boxes.to(device)
        objectness, class_maps, box_maps = model(images)
        loss, _ = anchor_free_loss(objectness, class_maps, box_maps, classes, boxes)
        predicted_classes, _, predicted_boxes, _ = decode_predictions(
            objectness, class_maps, box_maps
        )
        ious = aligned_iou(predicted_boxes, boxes)
        batch_size = images.shape[0]
        total_loss += float(loss) * batch_size
        correct += int((predicted_classes == classes).sum())
        iou_sum += float(ious.sum())
        iou50 += int((ious >= 0.5).sum())
        count += batch_size
    return {
        "val_loss": total_loss / count,
        "val_accuracy": correct / count,
        "val_mean_iou": iou_sum / count,
        "val_iou50": iou50 / count,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Train the anchor-free nut detector")
    parser.add_argument("--epochs", type=int, default=160)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--learning-rate", type=float, default=2e-3)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=PROJECT_ROOT / "runs" / "tiny_nut_anchor_free",
    )
    args = parser.parse_args()

    base = TrainConfig()
    config = TrainConfig(
        epochs=args.epochs,
        batch_size=args.batch_size,
        learning_rate=args.learning_rate,
        output_dir=args.output_dir,
        patience=40,
    )
    seed_everything(config.seed)
    config.output_dir.mkdir(parents=True, exist_ok=True)
    (config.output_dir / "config.json").write_text(
        json.dumps(config.serializable(), indent=2), encoding="utf-8"
    )
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    samples = read_samples(config.dataset_dir)
    train_indices, val_indices = stratified_split(
        samples, config.val_fraction, config.seed
    )
    save_split(config.output_dir / "split.json", samples, train_indices, val_indices)
    train_dataset = NutDataset(samples, train_indices, training=True, seed=config.seed)
    val_dataset = NutDataset(samples, val_indices, training=False, seed=config.seed)
    train_loader = DataLoader(
        train_dataset,
        batch_size=config.batch_size,
        shuffle=True,
        num_workers=0,
        pin_memory=device.type == "cuda",
    )
    val_loader = DataLoader(val_dataset, batch_size=config.batch_size, shuffle=False)

    model = TinyNutAnchorFree(config.num_classes).to(device)
    parameter_count = sum(parameter.numel() for parameter in model.parameters())
    optimizer = AdamW(
        model.parameters(), lr=config.learning_rate, weight_decay=config.weight_decay
    )
    scheduler = CosineAnnealingLR(optimizer, T_max=config.epochs, eta_min=1e-5)
    print(f"device={device} train={len(train_dataset)} val={len(val_dataset)}")
    print(f"parameters={parameter_count:,} fp32_size={parameter_count * 4 / 1024**2:.2f} MiB")

    history: list[dict[str, float | int]] = []
    best_score = -1.0
    epochs_without_improvement = 0
    start_time = time.time()
    for epoch in range(1, config.epochs + 1):
        train_dataset.set_epoch(epoch)
        model.train()
        train_loss = 0.0
        train_count = 0
        for images, classes, boxes in train_loader:
            images, classes, boxes = images.to(device), classes.to(device), boxes.to(device)
            optimizer.zero_grad(set_to_none=True)
            objectness, class_maps, box_maps = model(images)
            loss, _ = anchor_free_loss(objectness, class_maps, box_maps, classes, boxes)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 5.0)
            optimizer.step()
            train_loss += float(loss.detach()) * images.shape[0]
            train_count += images.shape[0]
        scheduler.step()

        metrics = validate(model, val_loader, device)
        row: dict[str, float | int] = {
            "epoch": epoch,
            "train_loss": train_loss / train_count,
            "learning_rate": optimizer.param_groups[0]["lr"],
            **metrics,
        }
        history.append(row)
        score = metrics["val_accuracy"] + metrics["val_mean_iou"]
        improved = score > best_score + 1e-4
        if improved:
            best_score = score
            epochs_without_improvement = 0
            torch.save(
                {
                    "model": model.state_dict(),
                    "config": config.serializable(),
                    "class_names": CLASS_NAMES,
                    "epoch": epoch,
                    "metrics": metrics,
                    "parameter_count": parameter_count,
                    "head": "anchor_free_56x56",
                },
                config.output_dir / "best_model.pt",
            )
        else:
            epochs_without_improvement += 1
        if epoch == 1 or epoch % 5 == 0 or improved:
            print(
                f"epoch={epoch:03d} train={row['train_loss']:.4f} "
                f"val={metrics['val_loss']:.4f} acc={metrics['val_accuracy']:.3f} "
                f"mIoU={metrics['val_mean_iou']:.3f} IoU50={metrics['val_iou50']:.3f}"
            )
        if epochs_without_improvement >= config.patience:
            print(f"early stopping at epoch {epoch}")
            break

    with (config.output_dir / "history.csv").open("w", newline="", encoding="utf-8") as file:
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
        "train_images": len(train_dataset),
        "validation_images": len(val_dataset),
    }
    (config.output_dir / "training_summary.json").write_text(
        json.dumps(summary, indent=2), encoding="utf-8"
    )
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
