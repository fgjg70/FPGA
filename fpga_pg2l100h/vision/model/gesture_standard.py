import json
from pathlib import Path


STANDARD_ID = "user_northern_reference_1_10_v1"
HAND_NAMES = [f"hand {number}" for number in range(1, 11)]
HAND_INDICES = list(range(3, 12)) + [2]
POSES = [
    "食指伸直，其余手指收起；不采用竖拇指",
    "食指和中指伸直，呈V形",
    "食指、中指、无名指伸直，拇指和小指收起",
    "食指、中指、无名指、小指伸直，拇指收起",
    "五指展开",
    "拇指和小指伸出，其余手指收起",
    "拇指、食指、中指的指尖相捏，其余手指收起",
    "拇指和食指伸出，呈八字形，其余手指收起",
    "食指弯曲成钩，其余手指收起；不采用另外三指展开的OK手势",
    "双手食指交叉成十字，其余手指收起；不采用握拳",
]


def definition():
    return {
        "id": STANDARD_ID,
        "authority": "User-provided gesture reference image; this is the project convention",
        "gestures": [dict(number=index + 1, name=name, pose=POSES[index])
                     for index, name in enumerate(HAND_NAMES)],
        "ten_requires_both_hands_in_one_box": True,
    }


def bank_classes(base_classes):
    names = list(base_classes)
    names[2] = "hand 10"
    return names


def require_standard(directory):
    path = Path(directory) / "gesture_standard.json"
    if not path.is_file() or json.loads(path.read_text(encoding="utf-8")) != definition():
        raise ValueError("Northern 1-10 data must declare gesture_standard.json; do not relabel the public fist-ten data")
