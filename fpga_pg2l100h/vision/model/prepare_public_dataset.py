import argparse
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
import hashlib
import io
import json
import math
from pathlib import Path
import random
import time
import urllib.request
import zipfile

import numpy as np
from PIL import Image

from network import CLASSES
from train import ROOT, mnist


COCO = "http://images.cocodataset.org"
GESTURE_REVISION = "2a9136b223064450ffde79d3f2e01c0de41baf09"
GESTURES = f"https://codeload.github.com/tz28/Chinese-number-gestures-recognition/zip/{GESTURE_REVISION}"


def download(url, path):
    if path.exists():
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".part")
    for attempt in range(4):
        try:
            with urllib.request.urlopen(url, timeout=35) as source, temporary.open("wb") as destination:
                while chunk := source.read(1024 * 1024):
                    destination.write(chunk)
            temporary.replace(path)
            return path
        except Exception:
            if attempt == 3:
                raise
            time.sleep(attempt + 1)


class RemoteZip(io.RawIOBase):
    def __init__(self, url):
        self.url = url
        with urllib.request.urlopen(urllib.request.Request(url, method="HEAD"), timeout=25) as response:
            self.length = int(response.headers["Content-Length"])
        self.position = 0

    def seekable(self):
        return True

    def tell(self):
        return self.position

    def seek(self, offset, whence=0):
        self.position = offset if whence == 0 else self.position + offset if whence == 1 else self.length + offset
        return self.position

    def read(self, size=-1):
        size = self.length - self.position if size < 0 else min(size, self.length - self.position)
        if size <= 0:
            return b""
        chunks = []
        remaining = size
        while remaining:
            count = min(remaining, 512 * 1024)
            for attempt in range(4):
                try:
                    request = urllib.request.Request(self.url, headers={"Range": f"bytes={self.position}-{self.position + count - 1}"})
                    with urllib.request.urlopen(request, timeout=30) as response:
                        expected = f"bytes {self.position}-{self.position + count - 1}/{self.length}"
                        if response.status != 206 or response.headers.get("Content-Range") != expected:
                            raise RuntimeError("COCO server did not honor the requested byte range")
                        content = response.read()
                    if len(content) != count:
                        raise RuntimeError("Incomplete COCO annotation byte range")
                    break
                except Exception:
                    if attempt == 3:
                        raise
                    time.sleep(attempt + 1)
            chunks.append(content)
            self.position += count
            remaining -= count
            if size > 512 * 1024:
                print(f"COCO annotation compressed bytes: {size - remaining}/{size}", flush=True)
        return b"".join(chunks)


def save_sample(destination, split, name, image, category, box, provenance, records):
    image_path = destination / "images" / split / (name + ".png")
    label_path = destination / "labels" / split / (name + ".txt")
    image_path.parent.mkdir(parents=True, exist_ok=True)
    label_path.parent.mkdir(parents=True, exist_ok=True)
    image.save(image_path)
    label = ""
    if category is not None:
        left, top, right, bottom = box
        label = f"{category} {(left + right) / 320:.9f} {(top + bottom) / 240:.9f} {(right - left) / 160:.9f} {(bottom - top) / 120:.9f}\n"
    label_path.write_text(label, encoding="ascii")
    records.append(dict(image=str(image_path.relative_to(destination)), split=split, category=category, **provenance))


def prepare_coco(cache, destination, count, seed, records):
    annotation_path = cache / "instances_val2017.json"
    if not annotation_path.exists():
        print("Fetching only the COCO val annotations from the official archive using byte ranges", flush=True)
        with zipfile.ZipFile(RemoteZip(COCO + "/annotations/annotations_trainval2017.zip")) as archive:
            annotation_path.write_bytes(archive.read("annotations/instances_val2017.json"))
    annotations = json.loads(annotation_path.read_text())
    images = {image["id"]: image for image in annotations["images"]}
    choices = defaultdict(list)
    target_categories = {1: 0, 2: 1, 47: 2}
    for annotation in annotations["annotations"]:
        if annotation["category_id"] in target_categories and not annotation.get("iscrowd"):
            left, top, width, height = annotation["bbox"]
            if min(width, height) >= 24 and width * height >= 1200:
                choices[target_categories[annotation["category_id"]]].append(annotation)
    generator = random.Random(seed)
    selected = []
    for category, candidates in sorted(choices.items()):
        generator.shuffle(candidates)
        split_counts = defaultdict(int)
        used = set()
        for annotation in candidates:
            image_id = annotation["image_id"]
            split = "val" if int(hashlib.sha256(f"coco-{image_id}".encode()).hexdigest()[:8], 16) % 5 == 0 else "train"
            limit = max(24, count // 4) if split == "val" else count
            if image_id in used or split_counts[split] >= limit:
                continue
            used.add(image_id)
            split_counts[split] += 1
            selected.append((annotation, category, split))
        if min(split_counts.values(), default=0) < 16 or len(split_counts) != 2:
            raise ValueError(f"Insufficient independent COCO samples for {CLASSES[category]}: {dict(split_counts)}")
        print(f"COCO {CLASSES[category]}: {dict(split_counts)}", flush=True)
    target_image_ids = {annotation["image_id"] for annotation in annotations["annotations"] if annotation["category_id"] in target_categories}
    background_candidates = sorted(set(images) - target_image_ids)
    generator.shuffle(background_candidates)
    backgrounds = []
    background_counts = defaultdict(int)
    for image_id in background_candidates:
        split = "val" if int(hashlib.sha256(f"coco-{image_id}".encode()).hexdigest()[:8], 16) % 5 == 0 else "train"
        if background_counts[split] < (16 if split == "val" else 64):
            backgrounds.append((image_id, split))
            background_counts[split] += 1
    needed = sorted({annotation["image_id"] for annotation, _, _ in selected} | {image_id for image_id, _ in backgrounds})

    def fetch_image(image_id):
        filename = images[image_id]["file_name"]
        return download(COCO + "/val2017/" + filename, cache / "coco_images" / filename)

    with ThreadPoolExecutor(max_workers=8) as executor:
        for index, _ in enumerate(executor.map(fetch_image, needed)):
            if index % 100 == 0:
                print(f"COCO photographs downloaded: {index + 1}/{len(needed)}", flush=True)
    for annotation, category, split in selected:
        source = cache / "coco_images" / images[annotation["image_id"]]["file_name"]
        left, top, width, height = annotation["bbox"]
        crop_width = max(width * 1.6, height * 1.6 * 4 / 3)
        crop_height = crop_width * 3 / 4
        crop_left = math.floor(left + width / 2 - crop_width / 2)
        crop_top = math.floor(top + height / 2 - crop_height / 2)
        crop_right = math.ceil(crop_left + crop_width)
        crop_bottom = math.ceil(crop_top + crop_height)
        with Image.open(source) as image:
            output = image.convert("RGB").crop((crop_left, crop_top, crop_right, crop_bottom)).resize((160, 120), Image.Resampling.BILINEAR)
        box = [(left - crop_left) * 160 / (crop_right - crop_left), (top - crop_top) * 120 / (crop_bottom - crop_top),
               (left + width - crop_left) * 160 / (crop_right - crop_left), (top + height - crop_top) * 120 / (crop_bottom - crop_top)]
        save_sample(destination, split, f"coco_{annotation['id']}", output, category, box,
                    dict(source="COCO 2017 val", group=f"coco-{annotation['image_id']}", annotation="original instance bounding box after crop", source_url=COCO + "/val2017/" + source.name), records)
    for image_id, split in backgrounds:
        source = cache / "coco_images" / images[image_id]["file_name"]
        with Image.open(source) as image:
            output = image.convert("RGB").resize((160, 120), Image.Resampling.BILINEAR)
        save_sample(destination, split, f"coco_background_{image_id}", output, None, None,
                    dict(source="COCO background", group=f"coco-{image_id}", annotation="COCO contains none of person, bicycle or cup"), records)
    return annotation_path


def prepare_gestures(cache, destination, per_group, seed, records, patch_size=88):
    archive_path = download(GESTURES, cache / "gestures.zip")
    generator = random.Random(seed)
    with zipfile.ZipFile(archive_path) as archive:
        groups = defaultdict(list)
        for name in archive.namelist():
            if "/resized_img/" not in name or not name.endswith(".jpg"):
                continue
            parts = Path(name).stem.split("_")
            label = int(parts[0])
            if 1 <= label <= 9:
                groups[(label, "_".join(parts[:-2]))].append(name)
        for label in range(1, 10):
            originals = sorted(key for key in groups if key[0] == label)
            generator.shuffle(originals)
            validation_groups = set(originals[:max(2, round(len(originals) * 0.2))])
            print(f"Hand {label}: {len(originals)} source photos, {len(validation_groups)} held out", flush=True)
            for group in originals:
                names = sorted(groups[group])
                generator.shuffle(names)
                split = "val" if group in validation_groups else "train"
                limit = min(per_group, 4) if split == "val" else per_group
                for index, name in enumerate(names[:limit]):
                    with Image.open(io.BytesIO(archive.read(name))) as image:
                        hand = image.convert("RGB").resize((patch_size, patch_size), Image.Resampling.BILINEAR)
                    output = Image.new("RGB", (160, 120), (240, 240, 240))
                    left, top = (160 - patch_size) // 2, (120 - patch_size) // 2
                    output.paste(hand, (left, top))
                    save_sample(destination, split, f"gesture_{group[1]}_{index}", output, label + 2, [left, top, left + patch_size, top + patch_size],
                                dict(source="tz28 Chinese number gestures", group="gesture-" + group[1], source_file=name,
                                     annotation="weak whole-photo patch rectangle, not a hand instance ground-truth box"), records)
        license_name = next(name for name in archive.namelist() if name.endswith("/LICENSE") and name.count("/") == 1)
        (destination / "GESTURES_LICENSE.txt").write_bytes(archive.read(license_name))


def prepare_digits(destination, count, seed, records, include_digits=True):
    generator = random.Random(seed)
    for split in ["train", "val"]:
        images, labels = mnist(split)
        images = np.rint(images[:, 0].numpy() * 255).astype(np.uint8)
        labels = labels.numpy()
        for label in (range(10) if include_digits else []):
            indices = np.flatnonzero(labels == label).tolist()
            generator.shuffle(indices)
            limit = count if split == "train" else max(20, count // 4)
            for index in indices[:limit]:
                digit = Image.fromarray(images[index])
                digit = digit.crop(digit.getbbox())
                height = generator.randint(40, 76)
                width = max(14, round(height * digit.width / digit.height))
                width = min(width, 84)
                digit = digit.resize((width, height), Image.Resampling.BILINEAR)
                patch = Image.fromarray(255 - np.asarray(digit)).convert("RGB")
                left = generator.randint(20, 140 - width)
                top = generator.randint(4, 116 - height)
                output = Image.new("RGB", (160, 120), (255, 255, 255))
                output.paste(patch, (left, top))
                save_sample(destination, split, f"mnist_{index}", output, label + 12, [left, top, left + width, top + height],
                            dict(source="MNIST " + split, group=f"mnist-{split}-{index}", annotation="synthetic digit patch rectangle"), records)
        noise_generator = np.random.default_rng(seed + (0 if split == "train" else 1))
        for index in range(40 if split == "train" else 12):
            shade = generator.randint(210, 255)
            noise = noise_generator.integers(-3, 4, (120, 160, 1))
            output = Image.fromarray(np.clip(shade + noise, 0, 255).astype(np.uint8).repeat(3, axis=2))
            save_sample(destination, split, f"blank_{index}", output, None, None, dict(source="synthetic blank", group=f"blank-{split}-{index}"), records)


def main():
    parser = argparse.ArgumentParser(description="Prepare a reproducible small COCO / Chinese gesture / MNIST experiment")
    parser.add_argument("--output", type=Path, default=ROOT / "model/checkpoints/public_dataset")
    parser.add_argument("--objects-per-class", type=int, default=240)
    parser.add_argument("--gestures-per-group", type=int, default=8)
    parser.add_argument("--digits-per-class", type=int, default=140)
    parser.add_argument("--seed", type=int, default=2026)
    parser.add_argument("--requested-only", action="store_true")
    parser.add_argument("--hand-patch-size", type=int, default=88, choices=range(64, 113))
    args = parser.parse_args()
    if (args.output / "provenance.json").exists():
        raise ValueError("Dataset already exists; use another output directory to avoid stale split images")
    args.output.mkdir(parents=True, exist_ok=True)
    cache = ROOT / "model/checkpoints/public_cache"
    cache.mkdir(parents=True, exist_ok=True)
    records = []
    annotation_path = prepare_coco(cache, args.output, args.objects_per_class, args.seed, records)
    prepare_gestures(cache, args.output, args.gestures_per_group, args.seed, records, args.hand_patch_size)
    prepare_digits(args.output, args.digits_per_class, args.seed, records, not args.requested_only)
    source_groups = {split: {record["group"] for record in records if record["split"] == split} for split in ["train", "val"]}
    if source_groups["train"] & source_groups["val"]:
        raise AssertionError("A source image group leaked across train and val")
    names = CLASSES[:12] if args.requested_only else CLASSES
    counts = {split: {name: sum(record["split"] == split and record["category"] == category for record in records)
                      for category, name in enumerate(names)} for split in ["train", "val"]}
    provenance = dict(seed=args.seed, counts=counts, records=records, source_group_overlap=0, gesture_repository_revision=GESTURE_REVISION,
                      hand_patch_size=args.hand_patch_size, requested_only=args.requested_only,
                      coco_annotation_sha256=hashlib.sha256(annotation_path.read_bytes()).hexdigest(),
                      gesture_archive_sha256=hashlib.sha256((cache / "gestures.zip").read_bytes()).hexdigest(),
                      limitations=["COCO val images are internally split by image ID; this is not full COCO benchmark evaluation",
                                   "Gesture source photo prefixes are held out; subject identities are unavailable",
                                   "Gesture rectangles describe pasted classification photos, not tight hand instance boxes",
                                   "One selected target per image; no physical OV7670 captures are included"])
    (args.output / "classes.json").write_text(json.dumps(names, indent=2) + "\n", encoding="utf-8")
    (args.output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(dict(counts=counts, source_group_overlap=0, samples=len(records)), indent=2), flush=True)


if __name__ == "__main__":
    main()
