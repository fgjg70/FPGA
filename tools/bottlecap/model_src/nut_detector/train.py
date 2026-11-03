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

from .config import CLASS_NAMES, TrainConfig
from .dataset import NutDataset, read_samples, save_split, stratified_split
from .losses import aligned_iou, detection_loss
from .model import TinyNutFPN, cxcywh_to_xyxy


def seed_everything(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)


@torch.no_grad()
def validate(
    model: TinyNutFPN,
    loader: DataLoader,
    device: torch.device,
    config: TrainConfig,
) -> dict[str, float]:
    model.eval()
    total_loss = 0.0
    correct = 0
    iou_sum = 0.0
    iou_50 = 0
    count = 0
    for images, classes, boxes in loader:
        images, classes, boxes = images.to(device), classes.to(device), boxes.to(device)
        logits, predicted_cxcywh = model(images)
        loss, _ = detection_loss(
            logits,
            predicted_cxcywh,
            classes,
            boxes,
            config.bbox_loss_weight,
            config.iou_loss_weight,
        )
        ious = aligned_iou(cxcywh_to_xyxy(predicted_cxcywh), boxes)
        batch_size = images.shape[0]
        total_loss += float(loss) * batch_size
        correct += int((logits.argmax(dim=1) == classes).sum())
        iou_sum += float(ious.sum())
        iou_50 += int((ious >= 0.5).sum())
        count += batch_size
    return {
        "val_loss": total_loss / count,
        "val_accuracy": correct / count,
        "val_mean_iou": iou_sum / count,
        "val_iou50": iou_50 / count,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Train the lightweight RA8 nut detector")
    parser.add_argument("--epochs", type=int, default=None)
    parser.add_argument("--batch-size", type=int, default=None)
    parser.add_argument("--learning-rate", type=float, default=None)
    parser.add_argument("--output-dir", type=Path, default=None)
    parser.add_argument("--device", choices=["auto", "cpu", "cuda"], default="auto")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    base = TrainConfig()
    config = TrainConfig(
        epochs=args.epochs or base.epochs,
        batch_size=args.batch_size or base.batch_size,
        learning_rate=args.learning_rate or base.learning_rate,
        output_dir=args.output_dir or base.output_dir,
    )
    seed_everything(config.seed)
    config.output_dir.mkdir(parents=True, exist_ok=True)
    (config.output_dir / "config.json").write_text(
        json.dumps(config.serializable(), indent=2), encoding="utf-8"
    )

    if args.device == "cuda" or (args.device == "auto" and torch.cuda.is_available()):
        device = torch.device("cuda")
    else:
        device = torch.device("cpu")
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
        num_workers=config.num_workers,
        pin_memory=device.type == "cuda",
    )
    val_loader = DataLoader(
        val_dataset,
        batch_size=config.batch_size,
        shuffle=False,
        num_workers=config.num_workers,
    )

    model = TinyNutFPN(config.num_classes).to(device)
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
            logits, predicted_cxcywh = model(images)
            loss, _ = detection_loss(
                logits,
                predicted_cxcywh,
                classes,
                boxes,
                config.bbox_loss_weight,
                config.iou_loss_weight,
            )
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=5.0)
            optimizer.step()
            train_loss += float(loss.detach()) * images.shape[0]
            train_count += images.shape[0]
        scheduler.step()

        metrics = validate(model, val_loader, device, config)
        row: dict[str, float | int] = {
            "epoch": epoch,
            "train_loss": train_loss / train_count,
            "learning_rate": optimizer.param_groups[0]["lr"],
            **metrics,
        }
        history.append(row)
        # Classification is primary; IoU breaks ties and rewards useful boxes.
        score = metrics["val_accuracy"] + 0.5 * metrics["val_mean_iou"]
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

