from __future__ import annotations

import math

import torch
from torch import nn
from torch.nn import functional as F

from .mobilenet_anchor_free import InvertedResidual
from .model import ConvBNReLU


def make_divisible(value: float, divisor: int = 8) -> int:
    return max(divisor, int(value + divisor / 2) // divisor * divisor)


class ResidualConvBlock(nn.Module):
    def __init__(self, channels: int) -> None:
        super().__init__()
        self.conv1 = ConvBNReLU(channels, channels, kernel_size=3)
        self.conv2 = nn.Sequential(
            nn.Conv2d(channels, channels, kernel_size=3, padding=1, bias=False),
            nn.BatchNorm2d(channels),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return F.relu(x + self.conv2(self.conv1(x)), inplace=True)


class EnhancedMobileNetV2Backbone(nn.Module):
    """Deeper/wider NPU-friendly backbone for fine-grained nut appearance."""

    def __init__(self, width_multiplier: float = 1.0) -> None:
        super().__init__()
        c1 = make_divisible(32 * width_multiplier)
        c2 = make_divisible(48 * width_multiplier)
        c3 = make_divisible(80 * width_multiplier)
        c4a = make_divisible(128 * width_multiplier)
        c4 = make_divisible(160 * width_multiplier)
        c5 = make_divisible(256 * width_multiplier)
        self.out_channels = (c2, c3, c4, c5)
        self.stem = ConvBNReLU(3, c1, stride=2)
        self.stage1 = nn.Sequential(
            InvertedResidual(c1, c1, stride=1, expansion=4),
            InvertedResidual(c1, c1, stride=1, expansion=4),
        )
        self.stage2 = nn.Sequential(
            InvertedResidual(c1, c2, stride=2, expansion=6),
            InvertedResidual(c2, c2, stride=1, expansion=6),
            InvertedResidual(c2, c2, stride=1, expansion=6),
        )
        self.stage3 = nn.Sequential(
            InvertedResidual(c2, c3, stride=2, expansion=6),
            InvertedResidual(c3, c3, stride=1, expansion=6),
            InvertedResidual(c3, c3, stride=1, expansion=6),
            InvertedResidual(c3, c3, stride=1, expansion=6),
        )
        self.stage4 = nn.Sequential(
            InvertedResidual(c3, c4a, stride=2, expansion=6),
            InvertedResidual(c4a, c4a, stride=1, expansion=6),
            InvertedResidual(c4a, c4, stride=1, expansion=6),
            InvertedResidual(c4, c4, stride=1, expansion=6),
            InvertedResidual(c4, c4, stride=1, expansion=6),
        )
        self.stage5 = nn.Sequential(
            InvertedResidual(c4, c5, stride=2, expansion=6),
            InvertedResidual(c5, c5, stride=1, expansion=6),
            InvertedResidual(c5, c5, stride=1, expansion=6),
        )

    def forward(self, x: torch.Tensor) -> tuple[torch.Tensor, ...]:
        x = self.stage1(self.stem(x))
        c2 = self.stage2(x)
        c3 = self.stage3(c2)
        c4 = self.stage4(c3)
        c5 = self.stage5(c4)
        return c2, c3, c4, c5


def prediction_tower(channels: int, depth: int) -> nn.Sequential:
    return nn.Sequential(*(ConvBNReLU(channels, channels, kernel_size=3) for _ in range(depth)))


class EnhancedNutAnchorFree(nn.Module):
    """Strong backbone + semantic FPN + decoupled object/class/box heads."""

    def __init__(
        self,
        num_classes: int = 4,
        fpn_channels: int = 128,
        backbone_width: float = 1.0,
    ) -> None:
        super().__init__()
        self.fpn_channels = fpn_channels
        self.backbone_width = backbone_width
        self.backbone = EnhancedMobileNetV2Backbone(backbone_width)
        c2, c3, c4, c5 = self.backbone.out_channels
        self.lateral5 = ConvBNReLU(c5, fpn_channels, kernel_size=1)
        self.lateral4 = ConvBNReLU(c4, fpn_channels, kernel_size=1)
        self.lateral3 = ConvBNReLU(c3, fpn_channels, kernel_size=1)
        self.lateral2 = ConvBNReLU(c2, fpn_channels, kernel_size=1)
        self.refine5 = ResidualConvBlock(fpn_channels)
        self.refine4 = ResidualConvBlock(fpn_channels)
        self.refine3 = ResidualConvBlock(fpn_channels)
        self.refine2 = ResidualConvBlock(fpn_channels)
        self.multi_scale_fusion = nn.Sequential(
            ConvBNReLU(fpn_channels * 3, fpn_channels, kernel_size=1),
            ResidualConvBlock(fpn_channels),
        )
        self.objectness_tower = prediction_tower(fpn_channels, depth=3)
        self.class_tower = prediction_tower(fpn_channels, depth=3)
        self.box_tower = prediction_tower(fpn_channels, depth=2)
        self.objectness_head = nn.Conv2d(fpn_channels, 1, kernel_size=1)
        self.class_head = nn.Conv2d(fpn_channels, num_classes, kernel_size=1)
        self.box_head = nn.Conv2d(fpn_channels, 4, kernel_size=1)
        self._initialize_heads()

    def _initialize_heads(self) -> None:
        nn.init.normal_(self.objectness_head.weight, 0, 0.01)
        nn.init.constant_(self.objectness_head.bias, math.log(0.10 / 0.90))
        nn.init.normal_(self.class_head.weight, 0, 0.01)
        nn.init.zeros_(self.class_head.bias)
        nn.init.normal_(self.box_head.weight, 0, 0.01)
        nn.init.zeros_(self.box_head.bias)
        with torch.no_grad():
            self.box_head.bias[2:].fill_(math.log(0.15 / 0.85))

    def forward(self, x: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        c2, c3, c4, c5 = self.backbone(x)
        p5 = self.refine5(self.lateral5(c5))
        p4 = self.refine4(self.lateral4(c4) + F.interpolate(p5, size=c4.shape[-2:], mode="nearest"))
        p3 = self.refine3(self.lateral3(c3) + F.interpolate(p4, size=c3.shape[-2:], mode="nearest"))
        p2 = self.refine2(self.lateral2(c2) + F.interpolate(p3, size=c2.shape[-2:], mode="nearest"))
        fused = self.multi_scale_fusion(
            torch.cat(
                [
                    p2,
                    F.interpolate(p3, size=p2.shape[-2:], mode="nearest"),
                    F.interpolate(p4, size=p2.shape[-2:], mode="nearest"),
                ],
                dim=1,
            )
        )
        return (
            self.objectness_head(self.objectness_tower(fused)),
            self.class_head(self.class_tower(fused)),
            self.box_head(self.box_tower(fused)),
        )
