from __future__ import annotations

import math

import torch
from torch import nn
from torch.nn import functional as F

from .mobilenet_anchor_free import InvertedResidual
from .model import ConvBNReLU, DepthwiseSeparable


def make_divisible(value: float, divisor: int = 8) -> int:
    return max(divisor, int(value + divisor / 2) // divisor * divisor)


class SlimMobileNetV2Backbone(nn.Module):
    """Channel-pruned version of the existing backbone; topology is unchanged."""

    def __init__(self, width_multiplier: float = 0.5) -> None:
        super().__init__()
        c_stem = make_divisible(16 * width_multiplier)
        c1 = make_divisible(16 * width_multiplier)
        c2 = make_divisible(24 * width_multiplier)
        c3 = make_divisible(32 * width_multiplier)
        c4a = make_divisible(64 * width_multiplier)
        c4b = make_divisible(96 * width_multiplier)
        c5 = make_divisible(160 * width_multiplier)
        self.out_channels = (c2, c3, c4b, c5)
        self.stem = ConvBNReLU(3, c_stem, stride=2)
        self.stage1 = InvertedResidual(c_stem, c1, stride=1, expansion=2)
        self.stage2 = nn.Sequential(
            InvertedResidual(c1, c2, stride=2),
            InvertedResidual(c2, c2, stride=1),
        )
        self.stage3 = nn.Sequential(
            InvertedResidual(c2, c3, stride=2),
            InvertedResidual(c3, c3, stride=1),
            InvertedResidual(c3, c3, stride=1),
        )
        self.stage4 = nn.Sequential(
            InvertedResidual(c3, c4a, stride=2),
            InvertedResidual(c4a, c4a, stride=1),
            InvertedResidual(c4a, c4a, stride=1),
            InvertedResidual(c4a, c4b, stride=1),
            InvertedResidual(c4b, c4b, stride=1),
        )
        self.stage5 = nn.Sequential(
            InvertedResidual(c4b, c5, stride=2),
            InvertedResidual(c5, c5, stride=1),
        )

    def forward(
        self, x: torch.Tensor
    ) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
        x = self.stage1(self.stem(x))
        c2 = self.stage2(x)
        c3 = self.stage3(c2)
        c4 = self.stage4(c3)
        c5 = self.stage5(c4)
        return c2, c3, c4, c5


class SlimMobileNetNutAnchorFree(nn.Module):
    def __init__(
        self,
        num_classes: int = 4,
        width_multiplier: float = 0.5,
        fpn_channels: int = 32,
    ) -> None:
        super().__init__()
        self.width_multiplier = width_multiplier
        self.fpn_channels = fpn_channels
        self.backbone = SlimMobileNetV2Backbone(width_multiplier)
        c2, c3, c4, c5 = self.backbone.out_channels
        self.lateral5 = ConvBNReLU(c5, fpn_channels, kernel_size=1)
        self.lateral4 = ConvBNReLU(c4, fpn_channels, kernel_size=1)
        self.lateral3 = ConvBNReLU(c3, fpn_channels, kernel_size=1)
        self.lateral2 = ConvBNReLU(c2, fpn_channels, kernel_size=1)
        self.refine4 = DepthwiseSeparable(fpn_channels, fpn_channels)
        self.refine3 = DepthwiseSeparable(fpn_channels, fpn_channels)
        self.refine2 = DepthwiseSeparable(fpn_channels, fpn_channels)
        self.head_features = nn.Sequential(
            DepthwiseSeparable(fpn_channels, fpn_channels),
            DepthwiseSeparable(fpn_channels, fpn_channels),
        )
        self.objectness_head = nn.Conv2d(fpn_channels, 1, kernel_size=1)
        self.class_head = nn.Conv2d(fpn_channels, num_classes, kernel_size=1)
        self.box_head = nn.Conv2d(fpn_channels, 4, kernel_size=1)
        self._initialize_heads()

    def _initialize_heads(self) -> None:
        nn.init.normal_(self.objectness_head.weight, 0, 0.01)
        nn.init.constant_(self.objectness_head.bias, -4.595)
        nn.init.normal_(self.class_head.weight, 0, 0.01)
        nn.init.zeros_(self.class_head.bias)
        nn.init.normal_(self.box_head.weight, 0, 0.01)
        nn.init.zeros_(self.box_head.bias)
        with torch.no_grad():
            self.box_head.bias[2:].fill_(math.log(0.15 / 0.85))

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
