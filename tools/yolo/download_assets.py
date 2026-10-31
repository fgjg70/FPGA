#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Download YOLO-Fastest v1.1 official cfg/weights + a small set of real
images (darknet sample set) used for calibration / end-to-end detection.

All downloads are cached under tools/yolo/data/.  Sizes are checked against
the values published by the upstream repo (cfg 9685 B, weights 1384268 B) so a
truncated / HTML-error download can never be mistaken for a valid asset.
Retries on connection reset (the network here occasionally drops).

Run:
  python tools/yolo/download_assets.py
"""
import hashlib
import os
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
IMG = os.path.join(DATA, "images")

CFG_URL = ("https://raw.githubusercontent.com/dog-qiuqiu/Yolo-Fastest/master/"
           "ModelZoo/yolo-fastest-1.1_coco/yolo-fastest-1.1.cfg")
W_URL = ("https://raw.githubusercontent.com/dog-qiuqiu/Yolo-Fastest/master/"
         "ModelZoo/yolo-fastest-1.1_coco/yolo-fastest-1.1.weights")
CFG_SIZE = 9685
W_SIZE = 1384268

# classic darknet data/ sample images (real photographs, various classes)
IMG_NAMES = [
    "dog.jpg", "dog_cat.jpg", "horses.jpg", "eagle.jpg", "giraffe.jpg",
    "kite.jpg", "person.jpg", "scream.jpg", "zidane.jpg", "test.jpg",
    "coco9k/000000000139.jpg",
]
IMG_BASE = "https://raw.githubusercontent.com/pjreddie/darknet/master/data/"


def fetch(url, path, expect=None, retries=8, timeout=60):
    if os.path.exists(path) and (expect is None or os.path.getsize(path) == expect):
        return path, True
    os.makedirs(os.path.dirname(path), exist_ok=True)
    last = None
    for i in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "dsh-agent"})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                data = r.read()
            if expect is not None and len(data) != expect:
                raise IOError("bad size %d != %d" % (len(data), expect))
            tmp = path + ".part"
            with open(tmp, "wb") as f:
                f.write(data)
            os.replace(tmp, path)
            return path, False
        except Exception as e:  # noqa: BLE001 - retry any network error
            last = e
            print("  retry %d/%d: %s: %s" % (i + 1, retries, type(e).__name__, e))
            time.sleep(2 + 2 * i)
    raise RuntimeError("download failed: %s (%s)" % (url, last))


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


def main():
    os.makedirs(IMG, exist_ok=True)
    cfg, _ = fetch(CFG_URL, os.path.join(DATA, "yolo-fastest-1.1.cfg"), CFG_SIZE)
    w, _ = fetch(W_URL, os.path.join(DATA, "yolo-fastest-1.1.weights"), W_SIZE)
    print("cfg    %s  %d B  sha256=%s" % (cfg, os.path.getsize(cfg), sha256(cfg)))
    print("weight %s  %d B  sha256=%s" % (w, os.path.getsize(w), sha256(w)))
    ok = 0
    for name in IMG_NAMES:
        dst = os.path.join(IMG, name.replace("/", "_"))
        try:
            fetch(IMG_BASE + name, dst)
            ok += 1
            print("image  %-48s %7d B" % (name, os.path.getsize(dst)))
        except Exception as e:  # noqa: BLE001
            print("image  %-48s SKIP (%s)" % (name, e))
    print("downloaded %d/%d sample images -> %s" % (ok, len(IMG_NAMES), IMG))
    return 0 if ok >= 10 else 1


if __name__ == "__main__":
    sys.exit(main())
