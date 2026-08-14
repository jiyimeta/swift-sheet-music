"""`SymbolNet`: a small anchor-free, CenterNet-style detector for the OMR
raster front end. Input scale is normalized upstream by construction —
one staff space is always the same number of pixels — so there is no
multi-scale pyramid: a plain top-down path back to stride 4 is the whole
neck.

Architecture: a stem of two stride-2 conv/BN/ReLU blocks takes the
1-channel tile straight to stride 4, then three residual stages walk it
down to stride 4 / 8 / 16 (channels `2w` / `3w` / `4w`). A top-down path
of bilinear upsample + 1x1 lateral (added) walks back from stride 16 to
stride 4, fused at `2w` channels throughout. A shared 3x3 conv, then
three 1x1 heads produce the heatmap logits / offset / geom tensors that
line up channel-for-channel with `dataset.SymbolTiles`'s targets.
"""

from __future__ import annotations

import torch
from torch import nn


def _conv_bn_relu(in_channels: int, out_channels: int, stride: int = 1) -> nn.Sequential:
    return nn.Sequential(
        nn.Conv2d(in_channels, out_channels, 3, stride=stride, padding=1, bias=False),
        nn.BatchNorm2d(out_channels),
        nn.ReLU(inplace=True),
    )


class _ResidualBlock(nn.Module):
    """A standard ResNet basic block: two 3x3 conv/BN, a skip connection
    (1x1 conv/BN when stride or channel count changes), ReLU after the
    add."""

    def __init__(self, in_channels: int, out_channels: int, stride: int = 1):
        super().__init__()
        self.conv1 = nn.Conv2d(in_channels, out_channels, 3, stride=stride, padding=1, bias=False)
        self.bn1 = nn.BatchNorm2d(out_channels)
        self.conv2 = nn.Conv2d(out_channels, out_channels, 3, padding=1, bias=False)
        self.bn2 = nn.BatchNorm2d(out_channels)
        self.relu = nn.ReLU(inplace=True)
        if stride != 1 or in_channels != out_channels:
            self.shortcut: nn.Module = nn.Sequential(
                nn.Conv2d(in_channels, out_channels, 1, stride=stride, bias=False),
                nn.BatchNorm2d(out_channels),
            )
        else:
            self.shortcut = nn.Identity()

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        out = self.relu(self.bn1(self.conv1(x)))
        out = self.bn2(self.conv2(out))
        out = out + self.shortcut(x)
        return self.relu(out)


class SymbolNet(nn.Module):
    """Tile -> `(heatmap_logits, offset, geom)`, all at stride 4.

    `heatmap_logits` has `num_classes` channels (raw logits — training
    applies `losses.focal`, which does its own sigmoid). `offset` has 2
    channels (sub-pixel remainder). `geom` has 4 channels (box
    regression). See `dataset.SymbolTiles.__getitem__` for the exact
    target semantics each head is trained against.
    """

    def __init__(self, num_classes: int = 62, width: int = 32):
        super().__init__()
        stage4_channels = 2 * width
        stage8_channels = 3 * width
        stage16_channels = 4 * width

        self.stem = nn.Sequential(
            _conv_bn_relu(1, width, stride=2),
            _conv_bn_relu(width, stage4_channels, stride=2),
        )

        self.stage4 = _ResidualBlock(stage4_channels, stage4_channels, stride=1)
        self.stage8 = _ResidualBlock(stage4_channels, stage8_channels, stride=2)
        self.stage16 = _ResidualBlock(stage8_channels, stage16_channels, stride=2)

        # Top-down laterals: 1x1 convs mapping each stage's channels down
        # to the stride-4 stage's width, so every level can be added.
        self.lateral16 = nn.Conv2d(stage16_channels, stage4_channels, 1)
        self.lateral8 = nn.Conv2d(stage8_channels, stage4_channels, 1)
        self.lateral4 = nn.Conv2d(stage4_channels, stage4_channels, 1)

        self.shared = _conv_bn_relu(stage4_channels, stage4_channels, stride=1)

        self.heatmap_head = nn.Conv2d(stage4_channels, num_classes, 1)
        self.offset_head = nn.Conv2d(stage4_channels, 2, 1)
        self.geom_head = nn.Conv2d(stage4_channels, 4, 1)

        # CenterNet prior: start every class predicting "empty" (~0.1
        # probability) so the focal loss isn't spent undoing a 0.5 prior
        # over every cell of every class before it can learn anything.
        nn.init.constant_(self.heatmap_head.bias, -2.19)

    def forward(self, x: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        stem = self.stem(x)
        c4 = self.stage4(stem)
        c8 = self.stage8(c4)
        c16 = self.stage16(c8)

        p16 = self.lateral16(c16)
        p8 = self.lateral8(c8) + nn.functional.interpolate(
            p16, size=c8.shape[-2:], mode="bilinear", align_corners=False)
        p4 = self.lateral4(c4) + nn.functional.interpolate(
            p8, size=c4.shape[-2:], mode="bilinear", align_corners=False)

        fused = self.shared(p4)
        return self.heatmap_head(fused), self.offset_head(fused), self.geom_head(fused)


class ExportWrapper(nn.Module):
    """Wraps a trained `SymbolNet` so the exported graph (Core ML / ONNX,
    a later task) emits heatmap *probabilities* directly, so the Swift
    decode doesn't repeat a sigmoid. Training keeps the raw logits
    `losses.focal` needs — this wrapper only exists for export, nothing
    else changes."""

    def __init__(self, model: SymbolNet):
        super().__init__()
        self.model = model

    @torch.no_grad()
    def forward(self, x: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        hm_logits, offset, geom = self.model(x)
        return torch.sigmoid(hm_logits), offset, geom
