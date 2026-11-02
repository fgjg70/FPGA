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
from gesture_standard import bank_classes, HAND_INDICES, HAND_NAMES
from network import CLASSES, decode
from evaluate_numeric import prediction_for_output


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
with tempfile.TemporaryDirectory(dir=ROOT / "validation") as directory:
    destination = Path(directory)
    for number in range(1, 11):
        frame = captured.copy()
        frame[10, number + 10] = 127
        save_frame(frame.tobytes(), destination, "session_ten", f"person_ten_{number}", "train", number, [18, 10, 46, 50], "hand")
    dataset = CameraDataset(destination, "train", HAND_NAMES, "hand")
    index = next(index for index, sample in enumerate(dataset.samples) if sample[2][0] == 2)
    actual, target = dataset[index]
    assert target["category"] == 2
    assert np.array_equal(actual.numpy()[0] * 128, frame)
    output = np.zeros((4, 4, 27), dtype=np.int32)
    output[1, 1, :5] = [100, 64, 64, 64, 64]
    output[1, 1, 7] = 100
    candidate = decode(output, HAND_INDICES, class_names=bank_classes(CLASSES))
    assert candidate["name"] == "hand 10" and candidate["category"] == 2
    candidate = decode(output, [2])
    assert candidate["name"] == "cup", "The label bank class names were changed globally"
    model = dict(enabled_classes=sorted(HAND_INDICES), object_threshold=72, class_margin_threshold=24)
    predicted, _, _ = prediction_for_output(output, model, "hand")
    assert predicted == 10, "Ten was confused with the no-target sentinel"
    output[:, :, 0] = 0
    predicted, _, _ = prediction_for_output(output, model, "hand")
    assert predicted is None
print("PASS training data: negative frames contain no retained glyphs; hand capture Q7 values round-trip exactly and reject the wrong mode")
