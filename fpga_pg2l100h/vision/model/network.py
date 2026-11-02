import numpy as np
import torch
from torch import nn
from torch.nn import functional


CLASSES = ["people", "bike", "cup"] + [f"hand {number}" for number in range(1, 10)] + [f"digit {number}" for number in range(10)]
LAYERS = [(1, 8, 3, 2), (8, 16, 3, 2), (16, 24, 3, 2),
          (24, 32, 3, 2), (32, 32, 3, 1), (32, 27, 1, 1)]


def weight_shift(weights):
    maximum = max(float(weights.detach().abs().max()), 1e-8)
    return min(15, max(0, int(np.floor(np.log2(127 / maximum)))))


def quantize_ste(values, scale):
    rounded = torch.round(values * scale) / scale
    return values + (rounded - values).detach()


class MicroYolo(nn.Module):
    def __init__(self):
        super().__init__()
        self.layers = nn.ModuleList(nn.Conv2d(inputs, outputs, kernel, stride, kernel // 2)
                                    for inputs, outputs, kernel, stride in LAYERS)

    def forward(self, pixels):
        values = pixels
        for index, layer in enumerate(self.layers):
            scale = 2 ** weight_shift(layer.weight)
            weights = quantize_ste(layer.weight, scale)
            bias = quantize_ste(layer.bias, scale * 128)
            values = functional.conv2d(values, weights, bias, stride=layer.stride, padding=layer.padding)
            if index + 1 != len(self.layers):
                values = quantize_ste(values.clamp(0, 127 / 128), 128)
        return values


def export_arrays(network):
    arrays = {}
    for index, layer in enumerate(network.layers):
        shift = weight_shift(layer.weight)
        arrays[f"weight_{index}"] = np.clip(np.rint(layer.weight.detach().cpu().numpy() * (2 ** shift)), -127, 127).astype(np.int8)
        arrays[f"bias_{index}"] = np.rint(layer.bias.detach().cpu().numpy() * (2 ** shift) * 128).astype(np.int32)
        arrays[f"shift_{index}"] = np.array(shift, dtype=np.uint8)
    return arrays


def integer_forward(pixels, arrays, intermediates=False):
    pixel_array = np.asarray(pixels)
    single = pixel_array.ndim == 2
    values = torch.as_tensor(pixel_array.copy(), dtype=torch.int64).reshape(-1, 1, 64, 64)
    stages = []
    for index, (_, _, kernel, stride) in enumerate(LAYERS):
        weights = torch.tensor(arrays[f"weight_{index}"].astype(np.int64))
        bias = torch.tensor(arrays[f"bias_{index}"].astype(np.int64))
        values = functional.conv2d(values, weights, bias, stride=stride, padding=kernel // 2)
        values = values >> int(arrays[f"shift_{index}"])
        if index + 1 != len(LAYERS):
            values = values.clamp(0, 127)
        stage = values.permute(0, 2, 3, 1).numpy().copy()
        stages.append(stage[0] if single else stage)
    return stages if intermediates else stages[-1]


def decode(output, enabled_classes, threshold=72, class_names=None):
    names = CLASSES if class_names is None else class_names
    best = None
    for row in range(4):
        for column in range(4):
            values = output[row, column]
            if int(values[0]) < threshold:
                continue
            category = max(enabled_classes, key=lambda label: int(values[5 + label]))
            center_x = (column * 16 * 128 + np.clip(values[1], 0, 127) * 16) // 128
            center_y = (row * 16 * 128 + np.clip(values[2], 0, 127) * 16) // 128
            width = max(4, min(64, int(values[3]) * 64 // 128))
            height = max(4, min(64, int(values[4]) * 64 // 128))
            box = [max(0, int(center_x) - width // 2), max(0, int(center_y) - height // 2),
                   min(63, int(center_x) + width // 2), min(63, int(center_y) + height // 2)]
            candidate = dict(category=category, name=names[category], objectness=int(values[0]), box=box)
            if best is None or candidate["objectness"] > best["objectness"]:
                best = candidate
    return best
