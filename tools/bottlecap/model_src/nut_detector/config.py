from __future__ import annotations

from dataclasses import asdict, dataclass
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class TrainConfig:
    dataset_dir: Path = PROJECT_ROOT / "nut_dataset_augmented_100"
    output_dir: Path = PROJECT_ROOT / "runs" / "tiny_nut_fpn"
    input_size: int = 224
    source_width: int = 320
    source_height: int = 240
    num_classes: int = 4
    batch_size: int = 8
    epochs: int = 180
    learning_rate: float = 2e-3
    weight_decay: float = 2e-4
    val_fraction: float = 0.25
    seed: int = 42
    patience: int = 35
    bbox_loss_weight: float = 6.0
    iou_loss_weight: float = 2.0
    num_workers: int = 0

    def serializable(self) -> dict[str, object]:
        data = asdict(self)
        data["dataset_dir"] = str(self.dataset_dir)
        data["output_dir"] = str(self.output_dir)
        return data


CLASS_NAMES = ["chickpea", "cashew", "dried_fruit", "walnut"]
