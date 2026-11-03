from __future__ import annotations

import math

import torch
from torch import nn
from torch.nn import functional as F

from .losses import aligned_iou
from .model import ConvBNReLU, DepthwiseSeparable, TinyResBackbone


GRID_SIZE = 56


class TinyNutAnchorFree(nn.Module):
    """Tiny FPN detector with a 56x56 anchor-free prediction grid."""

    def __init__(self, num_classes: int = 4) -> None:
        super().__init__()
        self.num_classes = num_classes
        self.backbone = TinyResBackbone()
        channels = 48
        self.lateral5 = ConvBNReLU(112, channels, kernel_size=1)
        self.lateral4 = ConvBNReLU(72, channels, kernel_size=1)
        self.lateral3 = ConvBNReLU(40, channels, kernel_size=1)
        self.lateral2 = ConvBNReLU(24, channels, kernel_size=1)
        self.refine4 = DepthwiseSeparable(channels, channels)
        self.refine3 = DepthwiseSeparable(channels, channels)
        self.refine2 = DepthwiseSeparable(channels, channels)
        self.head_features = DepthwiseSeparable(channels, channels)
        self.objectness_head = nn.Conv2d(channels, 1, kernel_size=1)
        self.class_head = nn.Conv2d(channels, num_classes, kernel_size=1)
        self.box_head = nn.Conv2d(channels, 4, kernel_size=1)
        self._initialize_heads()

    def _initialize_heads(self) -> None:
        nn.init.normal_(self.objectness_head.weight, 0, 0.01)
        nn.init.constant_(self.objectness_head.bias, -4.595)  # prior probability 0.01
        nn.init.normal_(self.class_head.weight, 0, 0.01)
        nn.init.zeros_(self.class_head.bias)
        nn.init.normal_(self.box_head.weight, 0, 0.01)
        nn.init.zeros_(self.box_head.bias)
        # Initial width/height prior is about 15% of the input dimensions.
        size_bias = math.log(0.15 / 0.85)
        with torch.no_grad():
            self.box_head.bias[2:].fill_(size_bias)

    def forward(
        self, x: torch.Tensor
    ) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        c2, c3, c4, c5 = self.backbone(x)
        p5 = self.lateral5(c5)
        p4 = self.refine4(
            self.lateral4(c4) + F.interpolate(p5, scale_factor=2.0, mode="nearest")
        )
        p3 = self.refine3(
            self.lateral3(c3) + F.interpolate(p4, scale_factor=2.0, mode="nearest")
        )
        p2 = self.refine2(
            self.lateral2(c2) + F.interpolate(p3, scale_factor=2.0, mode="nearest")
        )
        features = self.head_features(p2)
        return (
            self.objectness_head(features),
            self.class_head(features),
            self.box_head(features),
        )


def _gather_grid_values(values: torch.Tensor, flat_indices: torch.Tensor) -> torch.Tensor:
    # BxCxHxW -> Bx(HW)xC, then select one grid cell per batch.
    flattened = values.permute(0, 2, 3, 1).reshape(values.shape[0], -1, values.shape[1])
    batch = torch.arange(values.shape[0], device=values.device)
    return flattened[batch, flat_indices]


def decode_predictions(
    objectness_logits: torch.Tensor,
    class_logits: torch.Tensor,
    box_logits: torch.Tensor,
) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
    """Decode the strongest grid response into class, score and normalized xyxy."""
    batch_size, _, height, width = objectness_logits.shape
    objectness = torch.sigmoid(objectness_logits).flatten(1)
    flat_indices = objectness.argmax(dim=1)
    selected_objectness = objectness.gather(1, flat_indices[:, None]).squeeze(1)
    selected_classes = _gather_grid_values(class_logits, flat_indices)
    class_probabilities = torch.softmax(selected_classes, dim=1)
    confidence, class_indices = class_probabilities.max(dim=1)
    confidence = confidence * selected_objectness

    selected_boxes = torch.sigmoid(_gather_grid_values(box_logits, flat_indices))
    grid_y = torch.div(flat_indices, width, rounding_mode="floor").float()
    grid_x = (flat_indices % width).float()
    center_x = (grid_x + selected_boxes[:, 0]) / width
    center_y = (grid_y + selected_boxes[:, 1]) / height
    box_width = selected_boxes[:, 2]
    box_height = selected_boxes[:, 3]
    boxes_xyxy = torch.stack(
        [
            center_x - box_width * 0.5,
            center_y - box_height * 0.5,
            center_x + box_width * 0.5,
            center_y + box_height * 0.5,
        ],
        dim=1,
    ).clamp(0.0, 1.0)
    return class_indices, confidence, boxes_xyxy, flat_indices


def make_targets(
    target_xyxy: torch.Tensor, grid_size: int = GRID_SIZE
) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    """Create CenterNet-style heatmaps and center-cell box targets."""
    batch_size = target_xyxy.shape[0]
    device = target_xyxy.device
    heatmaps = torch.zeros(batch_size, 1, grid_size, grid_size, device=device)
    x1, y1, x2, y2 = target_xyxy.unbind(dim=1)
    center_x = (x1 + x2) * 0.5
    center_y = (y1 + y2) * 0.5
    box_width = (x2 - x1).clamp(min=1e-4)
    box_height = (y2 - y1).clamp(min=1e-4)
    grid_x_float = center_x * grid_size
    grid_y_float = center_y * grid_size
    grid_x = grid_x_float.floor().long().clamp(0, grid_size - 1)
    grid_y = grid_y_float.floor().long().clamp(0, grid_size - 1)

    axis = torch.arange(grid_size, device=device).float()
    yy, xx = torch.meshgrid(axis, axis, indexing="ij")
    for batch_index in range(batch_size):
        # A small Gaussian reduces the extreme foreground/background imbalance.
        sigma = max(
            1.0,
            min(
                float(box_width[batch_index] * grid_size),
                float(box_height[batch_index] * grid_size),
            )
            / 6.0,
        )
        gaussian = torch.exp(
            -(
                (xx - grid_x[batch_index].float()) ** 2
                + (yy - grid_y[batch_index].float()) ** 2
            )
            / (2.0 * sigma * sigma)
        )
        heatmaps[batch_index, 0] = gaussian
        heatmaps[batch_index, 0, grid_y[batch_index], grid_x[batch_index]] = 1.0

    flat_indices = grid_y * grid_size + grid_x
    box_targets = torch.stack(
        [
            grid_x_float - grid_x.float(),
            grid_y_float - grid_y.float(),
            box_width,
            box_height,
        ],
        dim=1,
    )
    return heatmaps, flat_indices, box_targets


def heatmap_focal_loss(logits: torch.Tensor, targets: torch.Tensor) -> torch.Tensor:
    probabilities = torch.sigmoid(logits).clamp(1e-5, 1.0 - 1e-5)
    positive = targets.eq(1.0)
    negative = targets.lt(1.0)
    negative_weights = (1.0 - targets).pow(4)
    positive_loss = -(probabilities.log()) * (1.0 - probabilities).pow(2) * positive
    negative_loss = -((1.0 - probabilities).log()) * probabilities.pow(2) * negative_weights * negative
    positive_count = positive.sum().clamp(min=1)
    return (positive_loss.sum() + negative_loss.sum()) / positive_count


def anchor_free_loss(
    objectness_logits: torch.Tensor,
    class_logits: torch.Tensor,
    box_logits: torch.Tensor,
    class_targets: torch.Tensor,
    target_xyxy: torch.Tensor,
) -> tuple[torch.Tensor, dict[str, torch.Tensor]]:
    heatmaps, flat_indices, box_targets = make_targets(target_xyxy)
    objectness_loss = heatmap_focal_loss(objectness_logits, heatmaps)
    selected_classes = _gather_grid_values(class_logits, flat_indices)
    class_loss = F.cross_entropy(selected_classes, class_targets)
    selected_boxes = torch.sigmoid(_gather_grid_values(box_logits, flat_indices))
    box_loss = F.smooth_l1_loss(selected_boxes, box_targets, beta=0.03)

    width = objectness_logits.shape[-1]
    grid_y = torch.div(flat_indices, width, rounding_mode="floor").float()
    grid_x = (flat_indices % width).float()
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
    iou_loss = 1.0 - aligned_iou(predicted_xyxy, target_xyxy).mean()
    total = objectness_loss + class_loss + 5.0 * box_loss + 2.0 * iou_loss
    return total, {
        "objectness_loss": objectness_loss.detach(),
        "class_loss": class_loss.detach(),
        "box_loss": box_loss.detach(),
        "iou_loss": iou_loss.detach(),
    }


class AnchorFreeExportModel(nn.Module):
    def __init__(self, model: TinyNutAnchorFree) -> None:
        super().__init__()
        self.model = model

    def forward(self, x: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        objectness, classes, boxes = self.model(x)
        class_indices, confidence, boxes_xyxy, _ = decode_predictions(
            objectness, classes, boxes
        )
        return class_indices, confidence, boxes_xyxy
