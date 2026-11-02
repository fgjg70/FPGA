import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import shutil

from network import CLASSES
from prepare_public_dataset import GESTURE_REVISION, prepare_gestures
from train import ROOT


def main():
    parser = argparse.ArgumentParser(description="Prepare Chinese gestures 1-9 with source-photo separation and digit/background negatives")
    parser.add_argument("--output", type=Path, default=ROOT / "model/checkpoints/gesture_dataset")
    parser.add_argument("--per-photo", type=int, default=64)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError("Use a new output directory to avoid retaining stale labels")
    args.output.mkdir(parents=True)
    records = []
    cache = ROOT / "model/checkpoints/public_cache"
    prepare_gestures(cache, args.output, args.per_photo, 2026, records, patch_size=112)
    for record in records:
        label = args.output / Path(record["image"]).with_suffix(".txt")
        label = args.output / "labels" / record["split"] / label.name
        values = label.read_text().split()
        values[0] = str(record["category"] - 3)
        label.write_text(" ".join(values) + "\n", encoding="ascii")
    previous = ROOT / "model/checkpoints/public_dataset"
    provenance = json.loads((previous / "provenance.json").read_text())
    for original in provenance["records"]:
        if original["category"] is not None and original["category"] < 12:
            continue
        source = previous / original["image"]
        target = args.output / "images" / original["split"] / source.name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        label = args.output / "labels" / original["split"] / source.with_suffix(".txt").name
        label.parent.mkdir(parents=True, exist_ok=True)
        label.write_text("", encoding="ascii")
        record = dict(original)
        record.update(image=str(target.relative_to(args.output)), category=None,
                      annotation="non-gesture negative; original domain: " + original["source"])
        records.append(record)
    groups = {split: {record["group"] for record in records if record["split"] == split} for split in ["train", "val"]}
    hashes = {split: {hashlib.sha256((args.output / record["image"]).read_bytes()).hexdigest()
                      for record in records if record["split"] == split} for split in ["train", "val"]}
    overlap = groups["train"] & groups["val"]
    if overlap or hashes["train"] & hashes["val"]:
        raise ValueError("Training and validation must have distinct source photos and image bytes")
    counts = {split: dict(Counter(CLASSES[record["category"]] if record["category"] is not None else "negative"
                                 for record in records if record["split"] == split)) for split in ["train", "val"]}
    metadata = dict(seed=2026, counts=counts, records=records, source_group_overlap=0,
                    gesture_repository_revision=GESTURE_REVISION,
                    gesture_archive_sha256=hashlib.sha256((cache / "gestures.zip").read_bytes()).hexdigest(),
                    limitations=["Small public dataset; held-out source photos are not a person-disjoint or real-OV7670 evaluation",
                                 "Gesture boxes describe the whole image patch, not manually annotated hand-instance boundaries",
                                 "Digit and background negatives do not cover arbitrary non-numeric gestures"])
    (args.output / "classes.json").write_text(json.dumps(CLASSES[3:12], indent=2) + "\n", encoding="utf-8")
    (args.output / "provenance.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(dict(counts=counts, source_group_overlap=0, image_hash_overlap=0), indent=2), flush=True)


if __name__ == "__main__":
    main()
