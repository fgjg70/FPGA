from __future__ import annotations

import argparse
import csv
import json
import random
import time
from pathlib import Path

import numpy as np
import torch
from torch.nn import functional as F
from torch.optim import AdamW
from torch.optim.lr_scheduler import CosineAnnealingLR
from torch.utils.data import DataLoader, WeightedRandomSampler

from .config import PROJECT_ROOT
from .mobilenet_anchor_free import MobileNetNutAnchorFree
from .mobilenet_anchor_free_slim import SlimMobileNetNutAnchorFree
from .multi_anchor_free import multi_anchor_free_loss
from .multi_dataset import MultiNutDataset, read_multi_split
from .train_multi_mobilenet_anchor_free import evaluate


DATASET_DIR = PROJECT_ROOT / "nut_dataset_multi_7to1"
TEACHER_CHECKPOINT = PROJECT_ROOT / "runs" / "mobilenet_nut_multi_anchor_free" / "best_model.pt"


def seed_everything(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    torch.cuda.manual_seed_all(seed)


def dense_distillation_loss(
    student: tuple[torch.Tensor, torch.Tensor, torch.Tensor],
    teacher: tuple[torch.Tensor, torch.Tensor, torch.Tensor],
) -> torch.Tensor:
    student_objectness, student_classes, student_boxes = student
    teacher_objectness, teacher_classes, teacher_boxes = (
        value.detach() for value in teacher
    )
    teacher_probability = torch.sigmoid(teacher_objectness)
    student_probability = torch.sigmoid(student_objectness)
    objectness_weight = 1.0 + 8.0 * teacher_probability
    objectness_loss = (
        (student_probability - teacher_probability).pow(2) * objectness_weight
    ).mean()

    temperature = 2.0
    class_kl = F.kl_div(
        F.log_softmax(student_classes / temperature, dim=1),
        F.softmax(teacher_classes / temperature, dim=1),
        reduction="none",
    ).sum(dim=1, keepdim=True) * (temperature**2)
    foreground_weight = teacher_probability.clamp(min=0.02)
    class_loss = (class_kl * foreground_weight).sum() / foreground_weight.sum()

    box_difference = (
        torch.sigmoid(student_boxes) - torch.sigmoid(teacher_boxes)
    ).abs().mean(dim=1, keepdim=True)
    box_loss = (box_difference * foreground_weight).sum() / foreground_weight.sum()
    return 2.0 * objectness_loss + class_loss + box_loss


def profile_parameters(model: torch.nn.Module) -> int:
    return sum(parameter.numel() for parameter in model.parameters())


def main() -> None:
    parser = argparse.ArgumentParser(description="Train a channel-pruned student with distillation")
    parser.add_argument("--width-multiplier", type=float, required=True)
    parser.add_argument("--fpn-channels", type=int, required=True)
    parser.add_argument("--epochs", type=int, default=24)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--num-workers", type=int, default=0)
    parser.add_argument("--learning-rate", type=float, default=1.2e-3)
    parser.add_argument("--distill-weight", type=float, default=0.6)
    parser.add_argument("--patience", type=int, default=6)
    parser.add_argument("--teacher-checkpoint", type=Path, default=TEACHER_CHECKPOINT)
    parser.add_argument("--init-checkpoint", type=Path, default=None)
    parser.add_argument("--dataset-dir", type=Path, default=DATASET_DIR)
    parser.add_argument("--no-online-augmentation", action="store_true")
    parser.add_argument("--real-night-weight", type=float, default=1.0)
    parser.add_argument(
        "--profile-weight",
        action="append",
        default=[],
        metavar="PROFILE=WEIGHT",
        help="Increase/decrease sampling frequency for a lighting profile; repeatable",
    )
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    seed = 20260805
    seed_everything(seed)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    train_samples = read_multi_split(args.dataset_dir, "train")
    test_samples = read_multi_split(args.dataset_dir, "test")
    train_dataset = MultiNutDataset(
        train_samples, training=not args.no_online_augmentation, seed=seed
    )
    test_dataset = MultiNutDataset(test_samples, training=False, seed=seed)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    profile_weights: dict[str, float] = {}
    for item in args.profile_weight:
        if "=" not in item:
            raise ValueError(f"Invalid --profile-weight {item!r}; expected PROFILE=WEIGHT")
        profile, raw_weight = item.rsplit("=", 1)
        weight = float(raw_weight)
        if not profile or weight <= 0:
            raise ValueError(f"Invalid --profile-weight {item!r}")
        profile_weights[profile] = weight
    if args.real_night_weight <= 0:
        raise ValueError("--real-night-weight must be positive")
    if args.real_night_weight != 1.0:
        profile_weights["real_night"] = (
            profile_weights.get("real_night", 1.0) * args.real_night_weight
        )
    train_sampler = None
    if profile_weights:
        sample_weights = [
            profile_weights.get(str(sample.get("lighting_profile", "original")), 1.0)
            for sample in train_samples
        ]
        sampler_generator = torch.Generator().manual_seed(seed)
        train_sampler = WeightedRandomSampler(
            sample_weights,
            num_samples=len(train_dataset),
            replacement=True,
            generator=sampler_generator,
        )
    train_loader = DataLoader(
        train_dataset,
        batch_size=args.batch_size,
        shuffle=train_sampler is None,
        sampler=train_sampler,
        num_workers=args.num_workers,
        pin_memory=device.type == "cuda",
        persistent_workers=args.num_workers > 0,
    )
    test_loader = DataLoader(
        test_dataset,
        batch_size=args.batch_size,
        shuffle=False,
        num_workers=args.num_workers,
        pin_memory=device.type == "cuda",
        persistent_workers=args.num_workers > 0,
    )

    teacher_checkpoint = None
    teacher = None
    if args.distill_weight > 0:
        teacher_checkpoint = torch.load(args.teacher_checkpoint, map_location=device)
        teacher = MobileNetNutAnchorFree(num_classes=4).to(device)
        teacher.load_state_dict(teacher_checkpoint["model"])
        teacher.eval()
        teacher.requires_grad_(False)
    student = SlimMobileNetNutAnchorFree(
        num_classes=4,
        width_multiplier=args.width_multiplier,
        fpn_channels=args.fpn_channels,
    ).to(device)
    initialized_epoch = None
    if args.init_checkpoint is not None:
        init_checkpoint = torch.load(args.init_checkpoint, map_location=device)
        student.load_state_dict(init_checkpoint["model"])
        initialized_epoch = init_checkpoint.get("epoch")
    parameter_count = profile_parameters(student)
    optimizer = AdamW(student.parameters(), lr=args.learning_rate, weight_decay=2e-4)
    scheduler = CosineAnnealingLR(optimizer, T_max=args.epochs, eta_min=1e-5)
    amp_enabled = device.type == "cuda"
    scaler = torch.cuda.amp.GradScaler(enabled=amp_enabled)
    config = {
        "dataset_dir": str(args.dataset_dir),
        "train_images": len(train_dataset),
        "test_images": len(test_dataset),
        "width_multiplier": args.width_multiplier,
        "fpn_channels": args.fpn_channels,
        "epochs": args.epochs,
        "batch_size": args.batch_size,
        "num_workers": args.num_workers,
        "real_night_weight": args.real_night_weight,
        "profile_weights": profile_weights,
        "learning_rate": args.learning_rate,
        "distill_weight": args.distill_weight,
        "seed": seed,
        "teacher_checkpoint": str(args.teacher_checkpoint.resolve()) if teacher is not None else None,
        "teacher_epoch": teacher_checkpoint.get("epoch") if teacher_checkpoint is not None else None,
        "initialized_from": str(args.init_checkpoint.resolve()) if args.init_checkpoint else None,
        "initialized_epoch": initialized_epoch,
        "online_augmentation": not args.no_online_augmentation,
        "max_detections": 4,
        "structured_pruning": "channel slimming with unchanged stage topology",
    }
    (args.output_dir / "config.json").write_text(
        json.dumps(config, indent=2), encoding="utf-8"
    )
    print(
        f"device={device} gpu={torch.cuda.get_device_name(0) if amp_enabled else 'none'} "
        f"train={len(train_dataset)} test={len(test_dataset)} params={parameter_count:,}",
        flush=True,
    )

    history: list[dict[str, float | int]] = []
    best_score = -1.0
    epochs_without_improvement = 0
    start_time = time.time()
    for epoch in range(1, args.epochs + 1):
        epoch_start = time.time()
        train_dataset.set_epoch(epoch)
        student.train()
        total_sum = supervised_sum = distill_sum = 0.0
        image_count = 0
        for images, classes, boxes, valid in train_loader:
            images = images.to(device, non_blocking=True)
            classes = classes.to(device, non_blocking=True)
            boxes = boxes.to(device, non_blocking=True)
            valid = valid.to(device, non_blocking=True)
            optimizer.zero_grad(set_to_none=True)
            with torch.cuda.amp.autocast(enabled=amp_enabled):
                student_outputs = student(images)
                supervised, _ = multi_anchor_free_loss(
                    *student_outputs, classes, boxes, valid
                )
                if teacher is not None:
                    with torch.no_grad():
                        teacher_outputs = teacher(images)
                    distillation = dense_distillation_loss(student_outputs, teacher_outputs)
                else:
                    distillation = supervised.new_zeros(())
                loss = supervised + args.distill_weight * distillation
            scaler.scale(loss).backward()
            scaler.unscale_(optimizer)
            torch.nn.utils.clip_grad_norm_(student.parameters(), 5.0)
            scaler.step(optimizer)
            scaler.update()
            batch_size = images.shape[0]
            total_sum += float(loss.detach()) * batch_size
            supervised_sum += float(supervised.detach()) * batch_size
            distill_sum += float(distillation.detach()) * batch_size
            image_count += batch_size
        scheduler.step()
        metrics = evaluate(student, test_loader, device)
        row: dict[str, float | int] = {
            "epoch": epoch,
            "train_loss": total_sum / image_count,
            "train_supervised_loss": supervised_sum / image_count,
            "train_distillation_loss": distill_sum / image_count,
            "learning_rate": optimizer.param_groups[0]["lr"],
            "epoch_seconds": time.time() - epoch_start,
            **metrics,
        }
        history.append(row)
        # Persist progress after every completed epoch so an interrupted desktop
        # session still retains the metrics collected so far.
        with (args.output_dir / "history.csv").open("w", newline="", encoding="utf-8") as file:
            writer = csv.DictWriter(file, fieldnames=list(history[0]))
            writer.writeheader()
            writer.writerows(history)
        score = metrics["test_f1"] + metrics["test_mean_iou"]
        if score > best_score + 1e-4:
            best_score = score
            epochs_without_improvement = 0
            torch.save(
                {
                    "model": student.state_dict(),
                    "config": config,
                    "class_names": ["chickpea", "cashew", "almond", "walnut"],
                    "epoch": epoch,
                    "metrics": metrics,
                    "parameter_count": parameter_count,
                    "head": "slim_multi_anchor_free_56x56_top4",
                    "width_multiplier": args.width_multiplier,
                    "fpn_channels": args.fpn_channels,
                },
                args.output_dir / "best_model.pt",
            )
        else:
            epochs_without_improvement += 1
        print(
            f"epoch={epoch:03d} train={row['train_loss']:.4f} "
            f"F1={metrics['test_f1']:.4f} mIoU={metrics['test_mean_iou']:.4f} "
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
