import numpy as np
from PIL import Image, ImageOps


VERSION = "digit-normalize-v2"


def prepare_image(image):
    image = image.convert("L")
    values = np.asarray(image)
    border = np.concatenate((values[0], values[-1], values[:, 0], values[:, -1]))
    if float(border.mean()) > 127:
        image = ImageOps.invert(image)
    bounds = image.point(lambda value: 255 if value > 20 else 0).getbbox()
    if bounds is None:
        raise ValueError("Draw a digit first")
    cropped = image.crop(bounds)
    ratio = 20 / max(cropped.size)
    size = tuple(max(1, round(dimension * ratio)) for dimension in cropped.size)
    normalized = Image.new("L", (28, 28))
    normalized.paste(cropped.resize(size, Image.Resampling.LANCZOS),
                     ((28 - size[0]) // 2, (28 - size[1]) // 2))
    values = np.asarray(normalized).astype(np.float64)
    total = values.sum()
    if total:
        coordinates = np.indices(values.shape)
        offset_y = round(13.5 - (coordinates[0] * values).sum() / total)
        offset_x = round(13.5 - (coordinates[1] * values).sum() / total)
        shifted = Image.new("L", (28, 28))
        shifted.paste(normalized, (offset_x, offset_y))
        normalized = shifted
    small = normalized.resize((16, 16), Image.Resampling.BILINEAR)
    return ((np.asarray(small).astype(np.uint16) + 1) >> 1).clip(0, 127).astype(np.uint8).reshape(256)
