from __future__ import annotations

import torch
from torch import nn
from torch.nn import functional as F

from .anchor_free import GRID_SIZE, heatmap_focal_loss
from .losses import aligned_iou


def _gather_multi(values: torch.Tensor, flat_indices: torch.Tensor) -> torch.Tensor:
    flattened = values.permute(0, 2, 3, 1).reshape(values.shape[0], -1, values.shape[1])
    batch = torch.arange(values.shape[0], device=values.device)[:, None]
    return flattened[batch, flat_indices]


def make_multi_targets(
    target_xyxy: torch.Tensor,
    valid: torch.Tensor,
    grid_size: int = GRID_SIZE,
) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    batch_size, max_objects, _ = target_xyxy.shape
    device = target_xyxy.device
    heatmaps = torch.zeros(batch_size, 1, grid_size, grid_size, device=device)
    x1, y1, x2, y2 = target_xyxy.unbind(dim=2)
    center_x, center_y = (x1 + x2) * 0.5, (y1 + y2) * 0.5
    box_width = (x2 - x1).clamp(min=1e-4)
    box_height = (y2 - y1).clamp(min=1e-4)
    grid_x_float, grid_y_float = center_x * grid_size, center_y * grid_size
    grid_x = grid_x_float.floor().long().clamp(0, grid_size - 1)
    grid_y = grid_y_float.floor().long().clamp(0, grid_size - 1)
    axis = torch.arange(grid_size, device=device).float()
    yy, xx = torch.meshgrid(axis, axis, indexing="ij")
    for batch_index in range(batch_size):
        for object_index in range(max_objects):
            if not bool(valid[batch_index, object_index]):
                continue
            sigma = max(
                1.0,
                min(
                    float(box_width[batch_index, object_index] * grid_size),
                    float(box_height[batch_index, object_index] * grid_size),
                )
                / 6.0,
            )
            gaussian = torch.exp(
                -(
                    (xx - grid_x[batch_index, object_index].float()) ** 2
                    + (yy - grid_y[batch_index, object_index].float()) ** 2
                )
                / (2.0 * sigma * sigma)
            )
            heatmaps[batch_index, 0] = torch.maximum(
                heatmaps[batch_index, 0], gaussian
            )
            heatmaps[
                batch_index,
                0,
                grid_y[batch_index, object_index],
                grid_x[batch_index, object_index],
            ] = 1.0
    flat_indices = grid_y * grid_size + grid_x
    box_targets = torch.stack(
        [
            grid_x_float - grid_x.float(),
            grid_y_float - grid_y.float(),
            box_width,
            box_height,
        ],
        dim=2,
    )
    return heatmaps, flat_indices, box_targets


def multi_anchor_free_loss(
    objectness_logits: torch.Tensor,
    class_logits: torch.Tensor,
    box_logits: torch.Tensor,
    class_targets: torch.Tensor,
    target_xyxy: torch.Tensor,
    valid: torch.Tensor,
) -> tuple[torch.Tensor, dict[str, torch.Tensor]]:
    heatmaps, flat_indices, box_targets = make_multi_targets(target_xyxy, valid)
    objectness_loss = heatmap_focal_loss(objectness_logits, heatmaps)
    selected_classes = _gather_multi(class_logits, flat_indices)[valid]
    class_loss = F.cross_entropy(selected_classes, class_targets[valid])
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
    total = objectness_loss + class_loss + 5.0 * box_loss + 2.0 * iou_loss
    return total, {
        "objectness_loss": objectness_loss.detach(),
        "class_loss": class_loss.detach(),
        "box_loss": box_loss.detach(),
        "iou_loss": iou_loss.detach(),
    }


def _pair_iou(box: torch.Tensor, boxes: torch.Tensor) -> torch.Tensor:
    top_left = torch.maximum(box[:2], boxes[:, :2])
    bottom_right = torch.minimum(box[2:], boxes[:, 2:])
    intersection = (bottom_right - top_left).clamp(min=0).prod(dim=1)
    box_area = (box[2:] - box[:2]).clamp(min=0).prod()
    boxes_area = (boxes[:, 2:] - boxes[:, :2]).clamp(min=0).prod(dim=1)
    return intersection / (box_area + boxes_area - intersection).clamp(min=1e-7)


def _class_aware_nms(
    boxes: torch.Tensor,
    scores: torch.Tensor,
    classes: torch.Tensor,
    threshold: float,
    max_detections: int,
) -> torch.Tensor:
    order = scores.argsort(descending=True)
    keep: list[torch.Tensor] = []
    while order.numel() > 0 and len(keep) < max_detections:
        current = order[0]
        keep.append(current)
        if order.numel() == 1:
            break
        remaining = order[1:]
        ious = _pair_iou(boxes[current], boxes[remaining])
        suppress = (classes[remaining] == classes[current]) & (ious > threshold)
        order = remaining[~suppress]
    if not keep:
        return torch.empty(0, dtype=torch.long, device=boxes.device)
    return torch.stack(keep)


@torch.no_grad()
def decode_multi_predictions(
    objectness_logits: torch.Tensor,
    class_logits: torch.Tensor,
    box_logits: torch.Tensor,
    max_detections: int = 4,
    confidence_threshold: float = 0.20,
    nms_threshold: float = 0.35,
    pre_nms_topk: int = 40,
) -> list[dict[str, torch.Tensor]]:
    batch_size, _, height, width = objectness_logits.shape
    objectness = torch.sigmoid(objectness_logits)
    local_maximum = objectness.eq(F.max_pool2d(objectness, kernel_size=3, stride=1, padding=1))
    peak_objectness = objectness * local_maximum
    class_probabilities = torch.softmax(class_logits, dim=1)
    class_probability, class_indices = class_probabilities.max(dim=1, keepdim=True)
    combined = peak_objectness * class_probability
    candidate_count = min(pre_nms_topk, height * width)
    scores, flat_indices = combined.flatten(1).topk(candidate_count, dim=1)
    results: list[dict[str, torch.Tensor]] = []
    flattened_classes = class_indices.flatten(1)
    flattened_objectness = objectness.flatten(1)
    flattened_class_probability = class_probability.flatten(1)
    for batch_index in range(batch_size):
        indices = flat_indices[batch_index]
        candidate_scores = scores[batch_index]
        keep_threshold = candidate_scores >= confidence_threshold
        indices = indices[keep_threshold]
        candidate_scores = candidate_scores[keep_threshold]
        if indices.numel() == 0:
            results.append(
                {
                    "classes": torch.empty(0, dtype=torch.long, device=objectness.device),
                    "scores": torch.empty(0, device=objectness.device),
                    "objectness": torch.empty(0, device=objectness.device),
                    "class_probability": torch.empty(0, device=objectness.device),
                    "boxes": torch.empty((0, 4), device=objectness.device),
                }
            )
            continue
        classes = flattened_classes[batch_index, indices]
        candidate_objectness = flattened_objectness[batch_index, indices]
        candidate_class_probability = flattened_class_probability[batch_index, indices]
        gathered_boxes = torch.sigmoid(
            box_logits[batch_index].permute(1, 2, 0).reshape(-1, 4)[indices]
        )
        grid_y = torch.div(indices, width, rounding_mode="floor").float()
        grid_x = (indices % width).float()
        center_x = (grid_x + gathered_boxes[:, 0]) / width
        center_y = (grid_y + gathered_boxes[:, 1]) / height
        boxes = torch.stack(
            [
                center_x - gathered_boxes[:, 2] * 0.5,
                center_y - gathered_boxes[:, 3] * 0.5,
                center_x + gathered_boxes[:, 2] * 0.5,
                center_y + gathered_boxes[:, 3] * 0.5,
            ],
            dim=1,
        ).clamp(0.0, 1.0)
        keep = _class_aware_nms(
            boxes, candidate_scores, classes, nms_threshold, max_detections
        )
        results.append(
            {
                "classes": classes[keep],
                "scores": candidate_scores[keep],
                "objectness": candidate_objectness[keep],
                "class_probability": candidate_class_probability[keep],
                "boxes": boxes[keep],
            }
        )
    return results


class MultiRawExportModel(nn.Module):
    """Keep the NPU graph simple; Top-K/NMS remains in MCU post-processing."""

    def __init__(self, model: nn.Module) -> None:
        super().__init__()
        self.model = model

    def forward(self, image: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        return self.model(image)
