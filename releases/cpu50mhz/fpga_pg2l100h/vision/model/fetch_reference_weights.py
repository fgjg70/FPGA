import argparse
import hashlib
import json
from pathlib import Path
import zipfile

from prepare_public_dataset import download
from train import ROOT


REFERENCES = [
    dict(filename="yolo_fastestv2_coco.pth", repository="dog-qiuqiu/Yolo-FastestV2",
         revision="ac2a5e3060bff76dd1e45f9b921dd77bfbeb194d", cache="yolo_fastestv2.zip",
         suffix="/modelzoo/coco2017-0.241078ap-model.pth", size=1158025,
         sha256="bdd956aa079bf1cdd3e0090a295ac26d73c40aef7b61b6405981b1afcbea985c",
         format="PyTorch state_dict, COCO 80 classes; not compatible with the fixed FPGA accelerator"),
    dict(filename="chinese_number_gestures.pb", repository="tz28/Chinese-number-gestures-recognition",
         revision="2a9136b223064450ffde79d3f2e01c0de41baf09", cache="gestures.zip",
         suffix="/model_200/digital_gesture.pb", size=6776847,
         sha256="69d593f024903bba4b0d415ec8a38a1588ae4ba6dcbdca8847f34c6aa7df96f7",
         format="TensorFlow frozen graph, Chinese gestures 0-10 classifier; not a YOLO hand detector"),
]


def main():
    parser = argparse.ArgumentParser(description="Download original reference checkpoints without executing repository code")
    parser.add_argument("--output", type=Path, default=ROOT / "model/checkpoints/pretrained")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    manifest = []
    for reference in REFERENCES:
        archive_path = download(f"https://codeload.github.com/{reference['repository']}/zip/{reference['revision']}",
                                ROOT / "model/checkpoints/public_cache" / reference["cache"])
        with zipfile.ZipFile(archive_path) as archive:
            entries = [name for name in archive.namelist() if name.endswith(reference["suffix"])]
            if len(entries) != 1:
                raise ValueError(f"Expected one original checkpoint: {reference['filename']}")
            contents = archive.read(entries[0])
        if len(contents) != reference["size"] or hashlib.sha256(contents).hexdigest() != reference["sha256"]:
            raise ValueError(f"Reference checkpoint digest mismatch: {reference['filename']}")
        (args.output / reference["filename"]).write_bytes(contents)
        manifest.append(reference)
        print(f"Verified {reference['filename']}: {len(contents)} bytes", flush=True)
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
