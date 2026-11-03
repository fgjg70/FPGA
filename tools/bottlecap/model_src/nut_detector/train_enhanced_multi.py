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
from torch.utils.data import DataLoader

from .enhanced_anchor_free import EnhancedNutAnchorFree
from .losses import aligned_iou
from .multi_anchor_free import _gather_multi, decode_multi_predictions, make_multi_targets
from .multi_dataset import MultiNutDataset, read_multi_split
from .train_multi_mobilenet_anchor_free import evaluate


def seed_everything(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    torch.cuda.manual_seed_all(seed)


def enhanced_detection_loss(
    objectness_logits: torch.Tensor,
    class_logits: torch.Tensor,
    box_logits: torch.Tensor,
    class_targets: torch.Tensor,
    target_xyxy: torch.Tensor,
    valid: torch.Tensor,
) -> tuple[torch.Tensor, dict[str, torch.Tensor]]:
    heatmaps, flat_indices, box_targets = make_multi_targets(target_xyxy, valid)
    # Keep focal-logarithm math in FP32. With the stronger objectness tower,
    # FP16 sigmoid can round saturated values to exactly 1 and produce 0*inf.
    objectness_fp32 = objectness_logits.float()
    heatmaps_fp32 = heatmaps.float()
    probabilities = torch.sigmoid(objectness_fp32).clamp(1e-5, 1.0 - 1e-5)
    positive = heatmaps_fp32.eq(1.0)
    negative = heatmaps_fp32.lt(1.0)
    negative_weights = (1.0 - heatmaps_fp32).pow(4)
    positive_loss = -(probabilities.log()) * (1.0 - probabilities).pow(2) * positive
    negative_loss = -((1.0 - probabilities).log()) * probabilities.pow(2) * negative_weights * negative
    positive_count = positive.sum().clamp(min=1)
    heatmap_loss = (4.0 * positive_loss.sum() + negative_loss.sum()) / positive_count

    selected_objectness = _gather_multi(objectness_fp32, flat_indices)[valid][:, 0]
    center_confidence_loss = F.softplus(-selected_objectness).mean()
    selected_classes = _gather_multi(class_logits, flat_indices)[valid]
    class_loss = F.cross_entropy(selected_classes, class_targets[valid], label_smoothing=0.02)
    selected_boxes = torch.sigmoid(_gather_multi(box_logits, flat_indices))[valid]
    valid_box_targets = box_targets[valid]
    box_loss = F.smooth_l1_loss(selected_boxes, valid_box_targets, beta=0.03)

    valid_indices = flat_indices[valid]
    width = objectness_logits.shape[-1]
    grid_y = torch.div(valid_indices, width, rounding_mode="floor").float()
    grid_x = (valid_indices % width).float()
    center_x = (grid_x + selected_boxes[:, 0]) / width
    center_y = (grid_y + selected_boxes[:, 1]) / width
    predicted_xyxy = torch.stack(
        [
            center_x - selected_boxes[:, 2] * 0.5,
            center_y - selected_boxes[:, 3] * 0.5,
            center_x + selected_boxes[:, 2] * 0.5,
            center_y + selected_boxes[:, 3] * 0.5,
        ],
        dim=1,
    ).clamp(0.0, 1.0)
    iou_loss = 1.0 - aligned_iou(predicted_xyxy, target_xyxy[valid]).mean()
    total = 2.0 * heatmap_loss + 2.0 * center_confidence_loss + 1.5 * class_loss + 5.0 * box_loss + 2.0 * iou_loss
    return total, {
        "heatmap_loss": heatmap_loss.detach(),
        "center_confidence_loss": center_confidence_loss.detach(),
        "class_loss": class_loss.detach(),
        "box_loss": box_loss.detach(),
        "iou_loss": iou_loss.detach(),
    }


def dense_distillation_loss(
    student: tuple[torch.Tensor, torch.Tensor, torch.Tensor],
    teacher: tuple[torch.Tensor, torch.Tensor, torch.Tensor],
) -> torch.Tensor:
    student_objectness, student_classes, student_boxes = student
    teacher_objectness, teacher_classes, teacher_boxes = (value.detach() for value in teacher)
    teacher_probability = torch.sigmoid(teacher_objectness.float())
    student_probability = torch.sigmoid(student_objectness.float())
    foreground_weight = teacher_probability.clamp(min=0.02)
    objectness_weight = 1.0 + 8.0 * teacher_probability
    objectness_loss = ((student_probability - teacher_probability).pow(2) * objectness_weight).mean()
    temperature = 2.0
    class_kl = F.kl_div(
        F.log_softmax(student_classes.float() / temperature, dim=1),
        F.softmax(teacher_classes.float() / temperature, dim=1),
        reduction="none",
    ).sum(dim=1, keepdim=True) * temperature**2
    class_loss = (class_kl * foreground_weight).sum() / foreground_weight.sum()
    box_difference = (torch.sigmoid(student_boxes.float()) - torch.sigmoid(teacher_boxes.float())).abs().mean(dim=1, keepdim=True)
    box_loss = (box_difference * foreground_weight).sum() / foreground_weight.sum()
    return 3.0 * objectness_loss + class_loss + box_loss


@torch.no_grad()
def evaluate_enhanced(model: torch.nn.Module, loader: DataLoader, device: torch.device) -> dict[str, float]:
    model.eval()
    image_count = tp = fp = fn = exact = count_correct = 0
    ious: list[float] = []
    objectness_values: list[float] = []
    from .train_multi_mobilenet_anchor_free import match_detections
    for images, classes, boxes, valid in loader:
        images, classes, boxes, valid = images.to(device), classes.to(device), boxes.to(device), valid.to(device)
        outputs = model(images)
        predictions = decode_multi_predictions(*outputs)
        image_count += images.shape[0]
        for index, prediction in enumerate(predictions):
            true_classes = classes[index][valid[index]]
            true_boxes = boxes[index][valid[index]]
            batch_tp, batch_fp, batch_fn, batch_ious = match_detections(prediction, true_classes, true_boxes)
            tp += batch_tp; fp += batch_fp; fn += batch_fn; ious.extend(batch_ious)
            objectness_values.extend(float(value) for value in prediction["objectness"])
            predicted_count, true_count = len(prediction["boxes"]), len(true_boxes)
            count_correct += int(predicted_count == true_count)
            exact += int(batch_tp == true_count and batch_fp == 0 and batch_fn == 0)
    precision = tp / max(1, tp + fp)
    recall = tp / max(1, tp + fn)
    return {
        "test_precision": precision,
        "test_recall": recall,
        "test_f1": 2 * precision * recall / max(1e-9, precision + recall),
        "test_mean_iou": float(np.mean(ious)) if ious else 0.0,
        "test_mean_objectness": float(np.mean(objectness_values)) if objectness_values else 0.0,
        "test_count_accuracy": count_correct / image_count,
        "test_exact_image_accuracy": exact / image_count,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Train or transfer-tune the enhanced multi-object detector")
    parser.add_argument("--dataset-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=36)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--num-workers", type=int, default=4)
    parser.add_argument("--learning-rate", type=float, default=7e-4)
    parser.add_argument("--fpn-channels", type=int, default=128)
    parser.add_argument("--backbone-width", type=float, default=1.0)
    parser.add_argument("--teacher-checkpoint", type=Path, default=None)
    parser.add_argument("--distill-weight", type=float, default=0.0)
    parser.add_argument(
        "--transfer-checkpoint",
        type=Path,
        default=None,
        help="Initialize matching feature/objectness/box weights from an existing checkpoint.",
    )
    parser.add_argument(
        "--reset-class-head",
        action="store_true",
        help="Do not reuse the old task's final class logits when transferring to new semantics.",
    )
    parser.add_argument(
        "--freeze-backbone-epochs",
        type=int,
        default=0,
        help="Keep the transferred backbone frozen for the first N epochs.",
    )
    parser.add_argument("--patience", type=int, default=8)
    parser.add_argument(
        "--class-names",
        nargs=4,
        default=["chickpea", "cashew", "almond", "walnut"],
        metavar=("CLASS1", "CLASS2", "CLASS3", "CLASS4"),
    )
    parser.add_argument("--domain", default="nut")
    args = parser.parse_args()
    seed = 20260807
    seed_everything(seed)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    train_samples = read_multi_split(args.dataset_dir, "train")
    test_samples = read_multi_split(args.dataset_dir, "test")
    train_dataset = MultiNutDataset(train_samples, training=False, seed=seed)
    test_dataset = MultiNutDataset(test_samples, training=False, seed=seed)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    train_loader = DataLoader(train_dataset, batch_size=args.batch_size, shuffle=True, num_workers=args.num_workers, pin_memory=device.type == "cuda", persistent_workers=args.num_workers > 0)
    test_loader = DataLoader(test_dataset, batch_size=args.batch_size, shuffle=False, num_workers=args.num_workers, pin_memory=device.type == "cuda", persistent_workers=args.num_workers > 0)
    model = EnhancedNutAnchorFree(
        num_classes=4,
        fpn_channels=args.fpn_channels,
        backbone_width=args.backbone_width,
    ).to(device)
    transfer_checkpoint = None
    transfer_skipped: list[str] = []
    if args.transfer_checkpoint is not None:
        transfer_checkpoint = torch.load(args.transfer_checkpoint, map_location=device, weights_only=False)
        source_state = transfer_checkpoint["model"]
        target_state = model.state_dict()
        compatible_state = {}
        for name, value in source_state.items():
            if args.reset_class_head and name.startswith("class_head."):
                transfer_skipped.append(name)
                continue
            if name in target_state and target_state[name].shape == value.shape:
                compatible_state[name] = value
            else:
                transfer_skipped.append(name)
        missing, unexpected = model.load_state_dict(compatible_state, strict=False)
        if unexpected:
            raise RuntimeError(f"Unexpected transfer keys: {unexpected}")
        if args.reset_class_head:
            torch.nn.init.normal_(model.class_head.weight, 0, 0.01)
            torch.nn.init.zeros_(model.class_head.bias)
        allowed_missing = {"class_head.weight", "class_head.bias"} if args.reset_class_head else set()
        disallowed_missing = [name for name in missing if name not in allowed_missing]
        if disallowed_missing:
            raise RuntimeError(f"Transfer checkpoint is incompatible; missing keys: {disallowed_missing}")
    teacher = None
    teacher_checkpoint = None
    if args.distill_weight > 0:
        if args.teacher_checkpoint is None:
            raise ValueError("--teacher-checkpoint is required when --distill-weight > 0")
        teacher_checkpoint = torch.load(args.teacher_checkpoint, map_location=device, weights_only=False)
        teacher = EnhancedNutAnchorFree(
            num_classes=4,
            fpn_channels=int(teacher_checkpoint.get("fpn_channels", 128)),
            backbone_width=float(teacher_checkpoint.get("backbone_width", 1.0)),
        ).to(device)
        teacher.load_state_dict(teacher_checkpoint["model"])
        teacher.eval().requires_grad_(False)
    parameter_count = sum(parameter.numel() for parameter in model.parameters())
    optimizer = AdamW(model.parameters(), lr=args.learning_rate, weight_decay=2e-4)
    scheduler = CosineAnnealingLR(optimizer, T_max=args.epochs, eta_min=1e-5)
    amp_enabled = device.type == "cuda"
    scaler = torch.cuda.amp.GradScaler(enabled=amp_enabled)
    config = {
        "dataset_dir": str(args.dataset_dir), "train_images": len(train_dataset), "test_images": len(test_dataset),
        "epochs": args.epochs, "batch_size": args.batch_size, "learning_rate": args.learning_rate,
        "fpn_channels": args.fpn_channels, "backbone_width": args.backbone_width,
        "parameter_count": parameter_count,
        "initialized_from": str(args.transfer_checkpoint) if transfer_checkpoint is not None else None,
        "transfer_source_domain": transfer_checkpoint.get("domain") if transfer_checkpoint is not None else None,
        "transfer_source_epoch": transfer_checkpoint.get("epoch") if transfer_checkpoint is not None else None,
        "transfer_skipped_keys": transfer_skipped,
        "freeze_backbone_epochs": args.freeze_backbone_epochs,
        "teacher_checkpoint": str(args.teacher_checkpoint) if teacher is not None else None,
        "teacher_epoch": teacher_checkpoint.get("epoch") if teacher_checkpoint is not None else None,
        "distill_weight": args.distill_weight,
        "model_variant": "enhanced_mobilenetv2_fpn_decoupled_head",
        "objectness_training": "4x focal positive + 2x heatmap + 2x center-confidence constraint",
        "max_detections": 4, "seed": seed,
        "class_names": args.class_names,
        "domain": args.domain,
    }
    (args.output_dir / "config.json").write_text(json.dumps(config, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"device={device} gpu={torch.cuda.get_device_name(0) if amp_enabled else 'none'} train={len(train_dataset)} test={len(test_dataset)} params={parameter_count:,}", flush=True)
    history: list[dict[str, float | int]] = []
    best_score = -1.0
    stale = 0
    start = time.time()
    for epoch in range(1, args.epochs + 1):
        epoch_start = time.time(); model.train()
        backbone_frozen = epoch <= args.freeze_backbone_epochs
        model.backbone.requires_grad_(not backbone_frozen)
        if backbone_frozen:
            model.backbone.eval()
        sums = {key: 0.0 for key in ["total", "supervised", "distill", "heatmap", "center", "class", "box", "iou"]}; seen = 0
        for images, classes, boxes, valid in train_loader:
            images, classes, boxes, valid = images.to(device, non_blocking=True), classes.to(device, non_blocking=True), boxes.to(device, non_blocking=True), valid.to(device, non_blocking=True)
            optimizer.zero_grad(set_to_none=True)
            with torch.cuda.amp.autocast(enabled=amp_enabled):
                student_outputs = model(images)
                supervised, parts = enhanced_detection_loss(*student_outputs, classes, boxes, valid)
                if teacher is not None:
                    with torch.no_grad():
                        teacher_outputs = teacher(images)
                    distillation = dense_distillation_loss(student_outputs, teacher_outputs)
                else:
                    distillation = supervised.new_zeros(())
                loss = supervised + args.distill_weight * distillation
            scaler.scale(loss).backward(); scaler.unscale_(optimizer); torch.nn.utils.clip_grad_norm_(model.parameters(), 5.0); scaler.step(optimizer); scaler.update()
            batch = images.shape[0]; seen += batch
            sums["total"] += float(loss.detach()) * batch
            sums["supervised"] += float(supervised.detach()) * batch
            sums["distill"] += float(distillation.detach()) * batch
            for source, target in [("heatmap_loss", "heatmap"), ("center_confidence_loss", "center"), ("class_loss", "class"), ("box_loss", "box"), ("iou_loss", "iou")]: sums[target] += float(parts[source]) * batch
        scheduler.step()
        metrics = evaluate_enhanced(model, test_loader, device)
        row: dict[str, float | int | bool] = {"epoch": epoch, "backbone_frozen": backbone_frozen, "train_loss": sums["total"] / seen, "train_supervised_loss": sums["supervised"] / seen, "train_distillation_loss": sums["distill"] / seen, "train_heatmap_loss": sums["heatmap"] / seen, "train_center_confidence_loss": sums["center"] / seen, "train_class_loss": sums["class"] / seen, "train_box_loss": sums["box"] / seen, "train_iou_loss": sums["iou"] / seen, "learning_rate": optimizer.param_groups[0]["lr"], "epoch_seconds": time.time() - epoch_start, **metrics}
        history.append(row)
        with (args.output_dir / "history.csv").open("w", newline="", encoding="utf-8") as file:
            writer = csv.DictWriter(file, fieldnames=list(history[0])); writer.writeheader(); writer.writerows(history)
        score = metrics["test_f1"] + metrics["test_mean_iou"] + 0.10 * metrics["test_mean_objectness"]
        if score > best_score + 1e-4:
            best_score = score; stale = 0
            torch.save({"model": model.state_dict(), "config": config, "class_names": args.class_names, "domain": args.domain, "epoch": epoch, "metrics": metrics, "parameter_count": parameter_count, "model_variant": config["model_variant"], "fpn_channels": args.fpn_channels, "backbone_width": args.backbone_width, "head": "enhanced_decoupled_anchor_free_56x56_top4"}, args.output_dir / "best_model.pt")
        else:
            stale += 1
        print(f"epoch={epoch:03d} loss={row['train_loss']:.4f} F1={metrics['test_f1']:.4f} mIoU={metrics['test_mean_iou']:.4f} obj={metrics['test_mean_objectness']:.4f} exact={metrics['test_exact_image_accuracy']:.4f} seconds={row['epoch_seconds']:.1f}", flush=True)
        if stale >= args.patience:
            print(f"early stopping at epoch {epoch}", flush=True); break
    summary = {"parameter_count": parameter_count, "fp32_parameter_size_mib": parameter_count * 4 / 1024**2, "int8_parameter_size_mib": parameter_count / 1024**2, "best_score": best_score, "epochs_completed": len(history), "elapsed_seconds": time.time() - start, "best_checkpoint": str(args.output_dir / "best_model.pt")}
    (args.output_dir / "training_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == "__main__":
    main()
