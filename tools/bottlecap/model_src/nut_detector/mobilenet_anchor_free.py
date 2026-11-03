from __future__ import annotations

import math

import torch
from torch import nn
from torch.nn import functional as F

from .model import ConvBNReLU, DepthwiseSeparable


class InvertedResidual(nn.Module):
    """MobileNetV2-style inverted residual block using NPU-friendly operators."""

    def __init__(
        self, in_channels: int, out_channels: int, stride: int, expansion: int = 4
    ) -> None:
        super().__init__()
        hidden_channels = in_channels * expansion
        layers: list[nn.Module] = []
        if expansion != 1:
            layers.append(ConvBNReLU(in_channels, hidden_channels, kernel_size=1))
        layers.extend(
            [
                ConvBNReLU(
                    hidden_channels,
                    hidden_channels,
                    kernel_size=3,
                    stride=stride,
                    groups=hidden_channels,
                ),
                nn.Conv2d(hidden_channels, out_channels, kernel_size=1, bias=False),
                nn.BatchNorm2d(out_channels),
            ]
        )
        self.block = nn.Sequential(*layers)
        self.use_residual = stride == 1 and in_channels == out_channels

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        result = self.block(x)
        if self.use_residual:
            result = result + x
        return result


class MobileNetV2Backbone(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.stem = ConvBNReLU(3, 16, stride=2)  # 112x112
        self.stage1 = InvertedResidual(16, 16, stride=1, expansion=2)
        self.stage2 = nn.Sequential(  # 56x56
            InvertedResidual(16, 24, stride=2),
            InvertedResidual(24, 24, stride=1),
        )
        self.stage3 = nn.Sequential(  # 28x28
            InvertedResidual(24, 32, stride=2),
            InvertedResidual(32, 32, stride=1),
            InvertedResidual(32, 32, stride=1),
        )
        self.stage4 = nn.Sequential(  # 14x14
            InvertedResidual(32, 64, stride=2),
            InvertedResidual(64, 64, stride=1),
            InvertedResidual(64, 64, stride=1),
            InvertedResidual(64, 96, stride=1),
            InvertedResidual(96, 96, stride=1),
        )
        self.stage5 = nn.Sequential(  # 7x7
            InvertedResidual(96, 160, stride=2),
            InvertedResidual(160, 160, stride=1),
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


class MobileNetNutAnchorFree(nn.Module):
    """Stronger MobileNetV2 backbone + 3-level FPN + 56x56 anchor-free head."""

    def __init__(self, num_classes: int = 4) -> None:
        super().__init__()
        self.backbone = MobileNetV2Backbone()
        channels = 64
        self.lateral5 = ConvBNReLU(160, channels, kernel_size=1)
        self.lateral4 = ConvBNReLU(96, channels, kernel_size=1)
        self.lateral3 = ConvBNReLU(32, channels, kernel_size=1)
        self.lateral2 = ConvBNReLU(24, channels, kernel_size=1)
        self.refine4 = DepthwiseSeparable(channels, channels)
        self.refine3 = DepthwiseSeparable(channels, channels)
        self.refine2 = DepthwiseSeparable(channels, channels)
        self.head_features = nn.Sequential(
            DepthwiseSeparable(channels, channels),
            DepthwiseSeparable(channels, channels),
        )
        self.objectness_head = nn.Conv2d(channels, 1, kernel_size=1)
        self.class_head = nn.Conv2d(channels, num_classes, kernel_size=1)
        self.box_head = nn.Conv2d(channels, 4, kernel_size=1)
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
