from __future__ import annotations

import csv
import math
import random
from collections import defaultdict
from pathlib import Path
from typing import Sequence

import numpy as np
import torch
from PIL import Image, ImageEnhance
from torch.utils.data import Dataset


MAX_OBJECTS = 4


def read_multi_split(dataset_dir: Path, split: str) -> list[dict[str, object]]:
    grouped: dict[str, list[dict[str, str]]] = defaultdict(list)
    with (dataset_dir / f"{split}_annotations.csv").open(encoding="utf-8-sig") as file:
        for row in csv.DictReader(file):
            grouped[row["image"]].append(row)
    samples: list[dict[str, object]] = []
    for image_name in sorted(grouped):
        rows = sorted(grouped[image_name], key=lambda row: int(row["object_index"]))
        samples.append(
            {
                "image": dataset_dir / split / image_name,
                "variant": rows[0].get("variant", "original"),
                "lighting_profile": rows[0].get("lighting_profile", "original"),
                "source_image": rows[0].get("source_image", image_name),
                "classes": np.array(
                    [int(row["class_id"]) - 1 for row in rows], dtype=np.int64
                ),
                "boxes": np.array(
                    [
                        [row["x_min"], row["y_min"], row["x_max"], row["y_max"]]
                        for row in rows
                    ],
                    dtype=np.float32,
                ),
            }
        )
    return samples


def _translate_edge(image: Image.Image, boxes: np.ndarray, dx: int, dy: int) -> tuple[Image.Image, np.ndarray]:
    pixels = np.asarray(image)
    pad_x, pad_y = abs(dx), abs(dy)
    padded = np.pad(pixels, ((pad_y, pad_y), (pad_x, pad_x), (0, 0)), mode="edge")
    start_x, start_y = pad_x - dx, pad_y - dy
    translated = padded[start_y : start_y + image.height, start_x : start_x + image.width]
    moved = boxes + np.array([dx, dy, dx, dy], dtype=np.float32)
    moved[:, [0, 2]] = np.clip(moved[:, [0, 2]], 0, image.width - 1)
    moved[:, [1, 3]] = np.clip(moved[:, [1, 3]], 0, image.height - 1)
    return Image.fromarray(translated), moved


def _rotate_edge(image: Image.Image, boxes: np.ndarray, angle: float) -> tuple[Image.Image, np.ndarray]:
    pad = 32
    pixels = np.pad(np.asarray(image), ((pad, pad), (pad, pad), (0, 0)), mode="edge")
    rotated = Image.fromarray(pixels).rotate(angle, resample=Image.Resampling.BILINEAR)
    rotated = rotated.crop((pad, pad, pad + image.width, pad + image.height))
    cx, cy = (image.width - 1) / 2.0, (image.height - 1) / 2.0
    radians = math.radians(angle)
    cosine, sine = math.cos(radians), math.sin(radians)
    output = []
    for x1, y1, x2, y2 in boxes:
        corners = np.array([[x1, y1], [x2, y1], [x2, y2], [x1, y2]], dtype=np.float32)
        offsets = corners - np.array([cx, cy], dtype=np.float32)
        transformed = np.empty_like(offsets)
        transformed[:, 0] = cosine * offsets[:, 0] + sine * offsets[:, 1] + cx
        transformed[:, 1] = -sine * offsets[:, 0] + cosine * offsets[:, 1] + cy
        output.append(
            [
                transformed[:, 0].min(),
                transformed[:, 1].min(),
                transformed[:, 0].max(),
                transformed[:, 1].max(),
            ]
        )
    result = np.asarray(output, dtype=np.float32)
    result[:, [0, 2]] = np.clip(result[:, [0, 2]], 0, image.width - 1)
    result[:, [1, 3]] = np.clip(result[:, [1, 3]], 0, image.height - 1)
    return rotated, result


def augment_multi(
    image: Image.Image, boxes: np.ndarray, rng: random.Random
) -> tuple[Image.Image, np.ndarray]:
    if rng.random() < 0.5:
        image = image.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
        boxes = boxes[:, [2, 1, 0, 3]]
        boxes[:, [0, 2]] = image.width - 1 - boxes[:, [0, 2]]
    if rng.random() < 0.12:
        image = image.transpose(Image.Transpose.FLIP_TOP_BOTTOM)
        boxes = boxes[:, [0, 3, 2, 1]]
        boxes[:, [1, 3]] = image.height - 1 - boxes[:, [1, 3]]
    if rng.random() < 0.55:
        min_dx = max(-12, math.ceil(float(-boxes[:, 0].min())))
        max_dx = min(12, math.floor(float(image.width - 1 - boxes[:, 2].max())))
        min_dy = max(-10, math.ceil(float(-boxes[:, 1].min())))
        max_dy = min(10, math.floor(float(image.height - 1 - boxes[:, 3].max())))
        image, boxes = _translate_edge(
            image,
            boxes,
            rng.randint(min_dx, max_dx) if min_dx <= max_dx else 0,
            rng.randint(min_dy, max_dy) if min_dy <= max_dy else 0,
        )
    if rng.random() < 0.45:
        image, boxes = _rotate_edge(image, boxes, rng.uniform(-7.0, 7.0))
    image = ImageEnhance.Brightness(image).enhance(rng.uniform(0.72, 1.28))
    image = ImageEnhance.Contrast(image).enhance(rng.uniform(0.80, 1.22))
    image = ImageEnhance.Color(image).enhance(rng.uniform(0.85, 1.15))
    if rng.random() < 0.30:
        gamma = rng.uniform(0.82, 1.22)
        table = [round(255 * ((value / 255) ** gamma)) for value in range(256)]
        image = image.point(table * 3)
    if rng.random() < 0.25:
        array = np.asarray(image, dtype=np.float32)
        noise_rng = np.random.default_rng(rng.randrange(2**32))
        array += noise_rng.normal(0.0, rng.uniform(1.0, 4.5), array.shape)
        image = Image.fromarray(np.clip(array, 0, 255).astype(np.uint8))
    return image, boxes


def preprocess_multi(
    image: Image.Image, boxes: np.ndarray
) -> tuple[torch.Tensor, torch.Tensor]:
    target_size, fitted_height = 224, 168
    resized = image.resize((target_size, fitted_height), Image.Resampling.BILINEAR)
    pixels = np.asarray(resized)
    top = (target_size - fitted_height) // 2
    bottom = target_size - fitted_height - top
    pixels = np.pad(pixels, ((top, bottom), (0, 0), (0, 0)), mode="edge").copy()
    transformed = boxes.copy()
    transformed[:, [0, 2]] *= target_size / image.width
    transformed[:, [1, 3]] = transformed[:, [1, 3]] * fitted_height / image.height + top
    transformed /= np.array([target_size - 1] * 4, dtype=np.float32)
    transformed = np.clip(transformed, 0.0, 1.0)
    tensor = torch.from_numpy(pixels).permute(2, 0, 1).float().div_(127.5).sub_(1.0)
    return tensor, torch.from_numpy(transformed.astype(np.float32))


class MultiNutDataset(Dataset):
    def __init__(
        self,
        samples: Sequence[dict[str, object]],
        training: bool,
        seed: int,
    ) -> None:
        self.samples = list(samples)
        self.training = training
        self.seed = seed
        self.epoch = 0

    def set_epoch(self, epoch: int) -> None:
        self.epoch = epoch

    def __len__(self) -> int:
        return len(self.samples)

    def __getitem__(self, index: int) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
        sample = self.samples[index]
        with Image.open(Path(sample["image"])) as opened:
            image = opened.convert("RGB")
        boxes = np.asarray(sample["boxes"], dtype=np.float32).copy()
        classes = np.asarray(sample["classes"], dtype=np.int64)
        if self.training:
            rng = random.Random(self.seed + self.epoch * 100_003 + index * 997)
            image, boxes = augment_multi(image, boxes, rng)
        image_tensor, boxes_tensor = preprocess_multi(image, boxes)
        padded_classes = torch.full((MAX_OBJECTS,), -1, dtype=torch.long)
        padded_boxes = torch.zeros((MAX_OBJECTS, 4), dtype=torch.float32)
        valid = torch.zeros((MAX_OBJECTS,), dtype=torch.bool)
        count = len(classes)
        padded_classes[:count] = torch.from_numpy(classes)
        padded_boxes[:count] = boxes_tensor
        valid[:count] = True
        return image_tensor, padded_classes, padded_boxes, valid
