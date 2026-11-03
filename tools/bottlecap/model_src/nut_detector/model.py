from __future__ import annotations

import torch
from torch import nn
from torch.nn import functional as F


class ConvBNReLU(nn.Sequential):
    def __init__(
        self,
        in_channels: int,
        out_channels: int,
        kernel_size: int = 3,
        stride: int = 1,
        groups: int = 1,
    ) -> None:
        padding = kernel_size // 2
        super().__init__(
            nn.Conv2d(
                in_channels,
                out_channels,
                kernel_size,
                stride,
                padding,
                groups=groups,
                bias=False,
            ),
            nn.BatchNorm2d(out_channels),
            nn.ReLU(inplace=True),
        )


class DepthwiseSeparable(nn.Module):
    def __init__(self, in_channels: int, out_channels: int, stride: int = 1) -> None:
        super().__init__()
        self.depthwise = ConvBNReLU(
            in_channels, in_channels, kernel_size=3, stride=stride, groups=in_channels
        )
        self.pointwise = ConvBNReLU(in_channels, out_channels, kernel_size=1)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.pointwise(self.depthwise(x))


class DSResidual(nn.Module):
    def __init__(self, channels: int) -> None:
        super().__init__()
        self.block = DepthwiseSeparable(channels, channels)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return F.relu(x + self.block(x), inplace=True)


class TinyResBackbone(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.stem = ConvBNReLU(3, 16, stride=2)  # 112x112
        self.stage1 = DSResidual(16)
        self.stage2 = nn.Sequential(  # 56x56
            DepthwiseSeparable(16, 24, stride=2),
            DSResidual(24),
        )
        self.stage3 = nn.Sequential(  # 28x28
            DepthwiseSeparable(24, 40, stride=2),
            DSResidual(40),
        )
        self.stage4 = nn.Sequential(  # 14x14
            DepthwiseSeparable(40, 72, stride=2),
            DSResidual(72),
        )
        self.stage5 = nn.Sequential(  # 7x7 context
            DepthwiseSeparable(72, 112, stride=2),
            DSResidual(112),
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


class TinyNutFPN(nn.Module):
    """Tiny ResNet-style detector with three-level top-down feature fusion."""

    def __init__(self, num_classes: int = 4) -> None:
        super().__init__()
        self.backbone = TinyResBackbone()
        fpn_channels = 48
        self.lateral5 = ConvBNReLU(112, fpn_channels, kernel_size=1)
        self.lateral4 = ConvBNReLU(72, fpn_channels, kernel_size=1)
        self.lateral3 = ConvBNReLU(40, fpn_channels, kernel_size=1)
        self.lateral2 = ConvBNReLU(24, fpn_channels, kernel_size=1)
        self.refine4 = DepthwiseSeparable(fpn_channels, fpn_channels)
        self.refine3 = DepthwiseSeparable(fpn_channels, fpn_channels)
        self.refine2 = DepthwiseSeparable(fpn_channels, fpn_channels)

        self.classifier = nn.Sequential(
            nn.Linear(fpn_channels * 3 * 2, 64),
            nn.ReLU(inplace=True),
            nn.Linear(64, num_classes),
        )
        self.box_spatial = nn.Sequential(
            DepthwiseSeparable(fpn_channels, 64, stride=2),  # 28x28
            DepthwiseSeparable(64, 64, stride=2),  # 14x14
            DepthwiseSeparable(64, 64, stride=2),  # 7x7
        )
        self.box_regressor = nn.Sequential(
            nn.Flatten(),
            nn.Linear(64 * 7 * 7, 64),
            nn.ReLU(inplace=True),
            nn.Linear(64, 4),
        )
        self._initialize_weights()

    def _initialize_weights(self) -> None:
        for module in self.modules():
            if isinstance(module, nn.Conv2d):
                nn.init.kaiming_normal_(module.weight, mode="fan_out", nonlinearity="relu")
            elif isinstance(module, nn.BatchNorm2d):
                nn.init.ones_(module.weight)
                nn.init.zeros_(module.bias)
            elif isinstance(module, nn.Linear):
                nn.init.normal_(module.weight, 0, 0.01)
                nn.init.zeros_(module.bias)

    @staticmethod
    def _pool(x: torch.Tensor) -> torch.Tensor:
        average = F.adaptive_avg_pool2d(x, 1).flatten(1)
        maximum = F.adaptive_max_pool2d(x, 1).flatten(1)
        return torch.cat([average, maximum], dim=1)

    def forward(self, x: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
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

        pooled = torch.cat([self._pool(p2), self._pool(p3), self._pool(p4)], dim=1)
        class_logits = self.classifier(pooled)
        bbox_cxcywh = torch.sigmoid(self.box_regressor(self.box_spatial(p2)))
        return class_logits, bbox_cxcywh


def cxcywh_to_xyxy(boxes: torch.Tensor) -> torch.Tensor:
    center_x, center_y, width, height = boxes.unbind(dim=-1)
    x1 = center_x - width * 0.5
    y1 = center_y - height * 0.5
    x2 = center_x + width * 0.5
    y2 = center_y + height * 0.5
    return torch.stack([x1, y1, x2, y2], dim=-1).clamp(0.0, 1.0)


def xyxy_to_cxcywh(boxes: torch.Tensor) -> torch.Tensor:
    x1, y1, x2, y2 = boxes.unbind(dim=-1)
    return torch.stack(
        [(x1 + x2) * 0.5, (y1 + y2) * 0.5, x2 - x1, y2 - y1], dim=-1
    )


class ExportModel(nn.Module):
    """Deployment wrapper: probabilities plus normalized xyxy box."""

    def __init__(self, model: TinyNutFPN) -> None:
        super().__init__()
        self.model = model

    def forward(self, x: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        logits, bbox_cxcywh = self.model(x)
        return torch.softmax(logits, dim=1), cxcywh_to_xyxy(bbox_cxcywh)
