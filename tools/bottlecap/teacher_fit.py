"""Adapt a 224-trained 2M teacher to the student's deployment input size.

Why this exists
---------------
``train_slim.py --distill-weight`` feeds the *same* image tensor to the teacher and
the student, i.e. the teacher must run at the student's input size. A teacher that
was trained at 224 collapses when evaluated at 96 (measured on the bottle-cap
teacher: F1 1.000 @224 -> 0.000 @96), so distillation with such a teacher is worse
than useless. This script fine-tunes the teacher at ``--input-size`` first, so the
teacher produces usable soft labels there.

Usage
-----
    python tools/bottlecap/teacher_fit.py \
        --checkpoint tools/bottlecap/model_src/best_model.pt \
        --dataset-dir <dataset root> \
        --input-size 96 --epochs 12 --output-dir results/teacher96

Writes ``best_model.pt`` (same checkpoint schema as the original, with
``config.input_size`` added) plus ``fit_report.json`` / ``history.csv``.
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
import time
from pathlib import Path

import torch
from torch.optim import AdamW
from torch.optim.lr_scheduler import CosineAnnealingLR
from torch.utils.data import DataLoader

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import train_slim as ts  # noqa: E402
from nut_detector.enhanced_anchor_free import EnhancedNutAnchorFree  # noqa: E402
from nut_detector.multi_anchor_free import multi_anchor_free_loss  # noqa: E402
from nut_detector.multi_dataset import MultiNutDataset, read_multi_split  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--dataset-dir", type=Path, default=ts.DEFAULT_DATASET_DIR)
    parser.add_argument("--input-size", type=int, default=96)
    parser.add_argument("--aspect-ratio", type=float, default=0.75)
    parser.add_argument("--epochs", type=int, default=12)
    parser.add_argument("--batch-size", type=int, default=32)
    # Must stay 0: the preprocess/grid monkeypatch lives in this process, and on
    # Windows a worker >0 spawns fresh interpreters that re-import nut_detector
    # without the patch (symptom: "size of tensor a (56) must match tensor b (24)").
    parser.add_argument("--num-workers", type=int, default=0)
    parser.add_argument("--learning-rate", type=float, default=2e-4)
    parser.add_argument("--weight-decay", type=float, default=2e-4)
    parser.add_argument("--limit-train", type=int, default=0)
    parser.add_argument("--limit-test", type=int, default=0)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()

    ts.seed_everything(ts.SEED)
    meta = ts.patch_nut_detector(args.input_size, args.aspect_ratio)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")

    train_samples = read_multi_split(args.dataset_dir, "train")
    test_samples = read_multi_split(args.dataset_dir, "test")
    if args.limit_train:
        train_samples = train_samples[: args.limit_train]
    if args.limit_test:
        test_samples = test_samples[: args.limit_test]
    train_dataset = MultiNutDataset(train_samples, training=True, seed=ts.SEED)
    test_dataset = MultiNutDataset(test_samples, training=False, seed=ts.SEED)
    train_loader = DataLoader(train_dataset, batch_size=args.batch_size, shuffle=True,
                              num_workers=args.num_workers, pin_memory=True,
                              drop_last=len(train_dataset) > args.batch_size)
    test_loader = DataLoader(test_dataset, batch_size=args.batch_size, shuffle=False,
                             num_workers=args.num_workers, pin_memory=True)

    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    saved = checkpoint.get("config") or {}
    model = EnhancedNutAnchorFree(
        num_classes=int(saved.get("num_classes", 4)),
        fpn_channels=int(saved.get("fpn_channels", 72)),
        backbone_width=float(saved.get("backbone_width", 0.55)),
    )
    model.load_state_dict(checkpoint["model"])
    model.to(device)
    params = sum(p.numel() for p in model.parameters())

    before = ts.base_evaluate(model, test_loader, device)
    print(f"before input={args.input_size} " + json.dumps(before), flush=True)

    optimizer = AdamW(model.parameters(), lr=args.learning_rate,
                      weight_decay=args.weight_decay)
    scheduler = CosineAnnealingLR(optimizer, T_max=max(1, args.epochs), eta_min=1e-5)
    amp = device.type == "cuda"
    scaler = torch.amp.GradScaler("cuda", enabled=amp)

    best = dict(before)
    best_epoch = int(checkpoint.get("epoch", -1))
    history: list[dict] = []
    start = time.time()
    for epoch in range(1, args.epochs + 1):
        epoch_start = time.time()
        train_dataset.set_epoch(epoch)
        model.train()
        total, count = 0.0, 0
        for images, classes, boxes, valid in train_loader:
            images = images.to(device, non_blocking=True)
            classes = classes.to(device, non_blocking=True)
            boxes = boxes.to(device, non_blocking=True)
            valid = valid.to(device, non_blocking=True)
            optimizer.zero_grad(set_to_none=True)
            with torch.amp.autocast("cuda", enabled=amp):
                outputs = model(images)
            with torch.amp.autocast("cuda", enabled=False):
                loss, _ = multi_anchor_free_loss(
                    *(value.float() for value in outputs), classes, boxes, valid
                )
            scaler.scale(loss).backward()
            scaler.unscale_(optimizer)
            torch.nn.utils.clip_grad_norm_(model.parameters(), 5.0)
            scaler.step(optimizer)
            scaler.update()
            total += float(loss.detach()) * images.shape[0]
            count += images.shape[0]
        scheduler.step()
        metrics = ts.base_evaluate(model, test_loader, device)
        row = {"epoch": epoch, "train_loss": total / max(1, count),
               "seconds": time.time() - epoch_start, **metrics}
        history.append(row)
        print(f"epoch={epoch:03d} loss={row['train_loss']:.4f} "
              f"F1={metrics['test_f1']:.4f} mIoU={metrics['test_mean_iou']:.4f} "
              f"seconds={row['seconds']:.1f}", flush=True)
        score = metrics["test_f1"] + metrics["test_mean_iou"]
        if score > best["test_f1"] + best["test_mean_iou"] + 1e-4:
            best, best_epoch = dict(metrics), epoch
            torch.save(
                {
                    "model": model.state_dict(),
                    "config": {**saved, "input_size": args.input_size,
                               "aspect_ratio": args.aspect_ratio},
                    "class_names": ts.CLASS_NAMES,
                    "epoch": epoch,
                    "metrics": metrics,
                    "parameter_count": params,
                    "model_variant": saved.get("model_variant",
                                               "enhanced_mobilenetv2_fpn_decoupled_head"),
                    "fpn_channels": int(saved.get("fpn_channels", 72)),
                    "backbone_width": float(saved.get("backbone_width", 0.55)),
                    "head": "teacher_fit",
                },
                args.output_dir / "best_model.pt",
            )

    with (args.output_dir / "history.csv").open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(history[0]))
        writer.writeheader()
        writer.writerows(history)
    report = {
        "checkpoint_in": str(args.checkpoint),
        "input_size": args.input_size,
        "aspect_ratio": args.aspect_ratio,
        "preprocess": meta["preprocess"],
        "grid_size": meta["grid_size"],
        "parameter_count": params,
        "before": before,
        "after": best,
        "best_epoch": best_epoch,
        "epochs_completed": len(history),
        "elapsed_seconds": time.time() - start,
        "verdict": ("usable as a 96-input distillation teacher"
                    if best.get("test_f1", 0) >= 0.9 else
                    "NOT usable: teacher cannot be adapted to this input size"),
    }
    (args.output_dir / "fit_report.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    print(json.dumps({k: report[k] for k in ("before", "after", "best_epoch", "verdict")},
                     indent=2, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
