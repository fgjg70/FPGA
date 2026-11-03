from __future__ import annotations

import torch
from torch.nn import functional as F

from .model import cxcywh_to_xyxy, xyxy_to_cxcywh


def aligned_iou(predicted: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
    intersection_x1 = torch.maximum(predicted[:, 0], target[:, 0])
    intersection_y1 = torch.maximum(predicted[:, 1], target[:, 1])
    intersection_x2 = torch.minimum(predicted[:, 2], target[:, 2])
    intersection_y2 = torch.minimum(predicted[:, 3], target[:, 3])
    intersection = (intersection_x2 - intersection_x1).clamp(min=0) * (
        intersection_y2 - intersection_y1
    ).clamp(min=0)
    predicted_area = (predicted[:, 2] - predicted[:, 0]).clamp(min=0) * (
        predicted[:, 3] - predicted[:, 1]
    ).clamp(min=0)
    target_area = (target[:, 2] - target[:, 0]).clamp(min=0) * (
        target[:, 3] - target[:, 1]
    ).clamp(min=0)
    return intersection / (predicted_area + target_area - intersection + 1e-7)


def detection_loss(
    class_logits: torch.Tensor,
    predicted_cxcywh: torch.Tensor,
    class_target: torch.Tensor,
    target_xyxy: torch.Tensor,
    bbox_weight: float,
    iou_weight: float,
) -> tuple[torch.Tensor, dict[str, torch.Tensor]]:
    class_loss = F.cross_entropy(class_logits, class_target)
    target_cxcywh = xyxy_to_cxcywh(target_xyxy)
    box_loss = F.smooth_l1_loss(predicted_cxcywh, target_cxcywh, beta=0.05)
    predicted_xyxy = cxcywh_to_xyxy(predicted_cxcywh)
    iou_loss = 1.0 - aligned_iou(predicted_xyxy, target_xyxy).mean()
    total = class_loss + bbox_weight * box_loss + iou_weight * iou_loss
    return total, {
        "class_loss": class_loss.detach(),
        "box_loss": box_loss.detach(),
        "iou_loss": iou_loss.detach(),
    }
