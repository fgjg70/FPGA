from pathlib import Path
import sys
import tempfile

import numpy as np
import torch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "model"))
from train_numeric import batch
from train_dataset import CameraDataset

sys.path.insert(0, str(ROOT / "tools"))
from capture_numeric import save_frame


torch.set_num_threads(2)
digits = torch.ones((10, 1, 28, 28))
empty = torch.zeros_like(digits)
labels = torch.arange(10)
pixels, targets = batch(digits, labels, digits, labels, empty, 256, torch.Generator().manual_seed(42), evaluation=True, mode="negative")
assert not targets["present"].any()
assert float(pixels.max()) < 0.2, "A forced negative retained foreground digit pixels"
pixels, targets = batch(digits, labels, digits, labels, empty, 256, torch.Generator().manual_seed(43), negative_ratio=0.6)
assert float(pixels[~targets["present"]].max()) < 0.2, "Negative oversampling retained a mislabeled digit"
assert pixels[targets["present"]].max() > 0.5
with tempfile.TemporaryDirectory(dir=ROOT / "validation") as directory:
    destination = Path(directory)
    captured = np.zeros((64, 64), dtype=np.uint8)
    captured[14:48, 22:42] = 127
    save_frame(captured.tobytes(), destination, "session_train", "person_train", "train", 1, [22, 14, 42, 48], "hand")
    dataset = CameraDataset(destination, "train", ["hand 1"], "hand")
    actual, _ = dataset[0]
    assert np.array_equal(actual.numpy()[0] * 128, captured), "Captured hand input was processed as a second RGB skin image"
    with np.testing.assert_raises(ValueError):
        CameraDataset(destination, "train", ["hand 1"], "label")[0]
print("PASS training data: negative frames contain no retained glyphs; hand capture Q7 values round-trip exactly and reject the wrong mode")
