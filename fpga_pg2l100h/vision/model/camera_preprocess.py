import numpy as np


def skin_mask(red, green, blue):
    red = np.asarray(red, dtype=np.uint16)
    green = np.asarray(green, dtype=np.uint16)
    blue = np.asarray(blue, dtype=np.uint16)
    return (red > 50) & (green > 25) & (blue > 10) & (red > green + 5) & (red > blue + 15)


def camera_input(rgb, mode="label"):
    rgb = np.asarray(rgb, dtype=np.uint16)
    red = (rgb[:, :, 0] >> 3) * 8 + (rgb[:, :, 0] >> 5)
    green = (rgb[:, :, 1] >> 2) * 4 + (rgb[:, :, 1] >> 6)
    blue = (rgb[:, :, 2] >> 3) * 8 + (rgb[:, :, 2] >> 5)
    values = np.zeros((64, 64), dtype=np.uint8)
    if mode == "hand":
        sampled = skin_mask(red, green, blue).astype(np.uint8) * 127
    else:
        sampled = (255 - ((red + green * 2 + blue) >> 2)) >> 1
    values[2:62] = sampled[::2, 16:144:2]
    return values
