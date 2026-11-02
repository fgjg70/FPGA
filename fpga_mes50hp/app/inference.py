from pathlib import Path

import numpy as np
from preprocessing import prepare_image


ROOT = Path(__file__).resolve().parents[1]


class LocalModel:
    def __init__(self, path=ROOT / "model/digit_model.npz"):
        with np.load(path, allow_pickle=False) as contents:
            self.weights = {name: contents[name].astype(np.int32) for name in ["w1", "b1", "w2", "b2"]}

    def infer(self, pixels):
        values = np.asarray(pixels, dtype=np.int32).reshape(256)
        if np.any(values < 0) or np.any(values > 127):
            raise ValueError("Pixels must be in range 0..127")
        hidden = np.clip((self.weights["w1"] @ values + self.weights["b1"]) >> 10, 0, 127)
        logits = self.weights["w2"] @ hidden + self.weights["b2"]
        return {"digit": int(logits.argmax()), "logits": logits.tolist(), "mode": "local preview"}
