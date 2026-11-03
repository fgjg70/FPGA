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
from torch.utils.data import DataLoader, WeightedRandomSampler

from .anchor_free import anchor_free_loss, decode_predictions
from .config import PROJECT_ROOT
from .dataset import NutDataset, read_fixed_split
from .losses import aligned_iou
from .mobilenet_anchor_free import MobileNetNutAnchorFree


DATASET_DIR = PROJECT_ROOT / "nut_dataset_balanced_7to1"
CLASS_NAMES = ["chickpea", "cashew", "almond", "walnut"]


def seed_everything(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)


@torch.no_grad()
def evaluate(
    model: MobileNetNutAnchorFree,
    loader: DataLoader,
    device: torch.device,
) -> dict[str, float]:
    model.eval()
    loss_sum = 0.0
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
        loss_sum += float(loss) * batch_size
        correct += int((predicted_classes == classes).sum())
        iou_sum += float(ious.sum())
        iou50 += int((ious >= 0.5).sum())
        count += batch_size
    return {
        "test_loss": loss_sum / count,
        "test_accuracy": correct / count,
        "test_mean_iou": iou_sum / count,
        "test_iou50": iou50 / count,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Train MobileNet anchor-free nut detector")
    parser.add_argument("--epochs", type=int, default=35)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--learning-rate", type=float, default=1.5e-3)
    parser.add_argument("--patience", type=int, default=8)
    parser.add_argument(
        "--init-checkpoint",
        type=Path,
        default=None,
        help="Load model weights from an existing .pt checkpoint before fine-tuning.",
    )
    parser.add_argument(
        "--dark-walnut-weight",
        type=float,
        default=1.0,
        help="Sampling multiplier for captures3 dark-walnut training frames.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=PROJECT_ROOT / "runs" / "mobilenet_nut_anchor_free",
    )
    args = parser.parse_args()
    seed = 20260804
    seed_everything(seed)
    args.output_dir.mkdir(parents=True, exist_ok=True)

    train_samples = read_fixed_split(DATASET_DIR, "train")
    test_samples = read_fixed_split(DATASET_DIR, "test")
    train_dataset = NutDataset(
        train_samples, range(len(train_samples)), training=True, seed=seed
    )
    test_dataset = NutDataset(
        test_samples, range(len(test_samples)), training=False, seed=seed
    )
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    workers = 0
    sampler = None
    if args.dark_walnut_weight != 1.0:
        sample_weights = [
            args.dark_walnut_weight
            if str(sample["source_id"]).startswith("captures3/")
            else 1.0
            for sample in train_samples
        ]
        sampler = WeightedRandomSampler(
            sample_weights,
            num_samples=len(train_samples),
            replacement=True,
            generator=torch.Generator().manual_seed(seed),
        )
    train_loader = DataLoader(
        train_dataset,
        batch_size=args.batch_size,
        shuffle=sampler is None,
        sampler=sampler,
        num_workers=workers,
        pin_memory=device.type == "cuda",
    )
    test_loader = DataLoader(
        test_dataset,
        batch_size=args.batch_size,
        shuffle=False,
        num_workers=workers,
    )

    model = MobileNetNutAnchorFree(num_classes=4).to(device)
    initialized_from = None
    initialized_epoch = None
    if args.init_checkpoint is not None:
        checkpoint = torch.load(
            args.init_checkpoint, map_location=device, weights_only=False
        )
        state_dict = checkpoint["model"] if "model" in checkpoint else checkpoint
        model.load_state_dict(state_dict)
        initialized_from = str(args.init_checkpoint.resolve())
        initialized_epoch = checkpoint.get("epoch")
        print(
            f"initialized_from={initialized_from} "
            f"checkpoint_epoch={initialized_epoch}"
        )
    parameter_count = sum(parameter.numel() for parameter in model.parameters())
    optimizer = AdamW(
        model.parameters(), lr=args.learning_rate, weight_decay=2e-4
    )
    scheduler = CosineAnnealingLR(optimizer, T_max=args.epochs, eta_min=1e-5)
    config = {
        "dataset_dir": str(DATASET_DIR),
        "train_images": len(train_dataset),
        "test_images": len(test_dataset),
        "epochs": args.epochs,
        "batch_size": args.batch_size,
        "learning_rate": args.learning_rate,
        "patience": args.patience,
        "initialized_from": initialized_from,
        "initialized_checkpoint_epoch": initialized_epoch,
        "dark_walnut_sampling_weight": args.dark_walnut_weight,
        "seed": seed,
        "class_names": CLASS_NAMES,
        "model": "MobileNetV2Backbone + 3-level FPN + 56x56 anchor-free head",
    }
    (args.output_dir / "config.json").write_text(
        json.dumps(config, indent=2), encoding="utf-8"
    )
    print(f"device={device} train={len(train_dataset)} test={len(test_dataset)}")
    print(f"parameters={parameter_count:,} fp32_size={parameter_count * 4 / 1024**2:.2f} MiB")

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
        for images, classes, boxes in train_loader:
            images, classes, boxes = images.to(device), classes.to(device), boxes.to(device)
            optimizer.zero_grad(set_to_none=True)
            objectness, class_maps, box_maps = model(images)
            loss, _ = anchor_free_loss(objectness, class_maps, box_maps, classes, boxes)
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
        score = metrics["test_accuracy"] + metrics["test_mean_iou"]
        improved = score > best_score + 1e-4
        if improved:
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
                    "head": "anchor_free_56x56",
                },
                args.output_dir / "best_model.pt",
            )
        else:
            epochs_without_improvement += 1
        print(
            f"epoch={epoch:03d} train={row['train_loss']:.4f} "
            f"test={metrics['test_loss']:.4f} acc={metrics['test_accuracy']:.4f} "
            f"mIoU={metrics['test_mean_iou']:.4f} IoU50={metrics['test_iou50']:.4f} "
            f"seconds={row['epoch_seconds']:.1f}"
        )
        if epochs_without_improvement >= args.patience:
            print(f"early stopping at epoch {epoch}")
            break

    with (args.output_dir / "history.csv").open(
        "w", newline="", encoding="utf-8"
    ) as file:
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
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
