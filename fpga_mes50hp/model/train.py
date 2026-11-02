import argparse
import gzip
import hashlib
import json
from pathlib import Path
import struct
import urllib.request

import numpy as np
from PIL import Image
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "app"))
from preprocessing import VERSION, prepare_image
from sklearn.neural_network import MLPClassifier
from threadpoolctl import threadpool_limits


ROOT = Path(__file__).resolve().parent
FILES = {
    "train-images-idx3-ubyte.gz": "f68b3c2dcbeaaa9fbdd348bbdeb94873",
    "train-labels-idx1-ubyte.gz": "d53e105ee54ea40749a09fcbcd1e9432",
    "t10k-images-idx3-ubyte.gz": "9fb629c4189551a2d022fa330f9573f3",
    "t10k-labels-idx1-ubyte.gz": "ec29112dd5afa0611ce80d1b7f02629c",
}
BASE_URL = "https://ossci-datasets.s3.amazonaws.com/mnist/"


def load_mnist(cache):
    cache.mkdir(parents=True, exist_ok=True)
    arrays = []
    for filename, expected in FILES.items():
        path = cache / filename
        if not path.exists():
            print("Downloading", filename, flush=True)
            urllib.request.urlretrieve(BASE_URL + filename, path)
        if hashlib.md5(path.read_bytes()).hexdigest() != expected:
            raise ValueError("MNIST checksum mismatch: " + filename)
        raw = gzip.decompress(path.read_bytes())
        magic, count = struct.unpack_from(">II", raw)
        if magic == 2051:
            images = np.frombuffer(raw, np.uint8, offset=16).reshape(count, 28, 28)
            arrays.append(np.stack([prepare_image(Image.fromarray(image)) for image in images]).astype(np.int8))
        elif magic == 2049:
            arrays.append(np.frombuffer(raw, np.uint8, offset=8).copy())
        else:
            raise ValueError("Unexpected IDX file: " + filename)
    return arrays


def integer_forward(images, weights):
    flat = images.reshape(-1, 256).astype(np.int32)
    hidden = np.clip((flat @ weights["w1"].astype(np.int32).T + weights["b1"]) >> 10, 0, 127)
    logits = hidden @ weights["w2"].astype(np.int32).T + weights["b2"]
    return logits


def c_array(name, values, kind):
    rows = values.reshape(-1, values.shape[-1]) if values.ndim > 1 else [values]
    declaration = f"static const {kind} {name}[{values.size}] __attribute__((aligned(4))) = {{\n"
    lines = []
    for row in rows:
        for offset in range(0, len(row), 16):
            lines.append("    " + ", ".join(str(int(value)) for value in row[offset:offset + 16]) + ",")
    return declaration + "\n".join(lines) + "\n};\n"


def export(model, images, labels, float_accuracy, epochs, seed):
    weights = {
        "w1": np.rint(model.coefs_[0].T * 128).clip(-127, 127).astype(np.int8),
        "b1": np.rint(model.intercepts_[0] * 16384).astype(np.int32),
        "w2": np.rint(model.coefs_[1].T * 64).clip(-127, 127).astype(np.int8),
        "b2": np.rint(model.intercepts_[1] * 1024).astype(np.int32),
    }
    logits = integer_forward(images, weights)
    predictions = logits.argmax(axis=1)
    accuracy = float((predictions == labels).mean())
    np.savez(ROOT / "digit_model.npz", **weights)
    header = "#ifndef DIGIT_MODEL_H\n#define DIGIT_MODEL_H\n\n#include <stdint.h>\n\n"
    for name, values in weights.items():
        header += c_array("digit_" + name, values, "int8_t" if name.startswith("w") else "int32_t") + "\n"
    header += "#define DIGIT_HIDDEN_SHIFT 10\n\n#endif\n"
    (ROOT / "digit_model.h").write_text(header, encoding="utf-8")
    selected = []
    for digit in range(10):
        matches = np.flatnonzero((labels == digit) & (predictions == digit))
        selected.append(int(matches[0]))
    sample_images = images[selected].reshape(10, 256)
    samples = {"images": sample_images.tolist(), "labels": labels[selected].tolist(),
               "logits": logits[selected].tolist(), "mnist_test_indices": selected}
    (ROOT / "samples.json").write_text(json.dumps(samples, indent=2) + "\n", encoding="utf-8")
    for digit, image in enumerate(sample_images):
        (ROOT / f"sample_{digit}.hex").write_text("\n".join(f"{int(value):02x}" for value in image) + "\n", encoding="ascii")
    report = {
        "architecture": [256, 32, 10], "input": "shared crop/center/resize then INT8 grayscale",
        "preprocessing_version": VERSION,
        "hidden": "clamp((input @ w1.T + b1) >> 10, 0, 127)",
        "output": "hidden @ w2.T + b2; argmax, no softmax",
        "seed": seed, "epochs": epochs, "train_samples": 60000, "test_samples": len(labels),
        "float_test_accuracy": float_accuracy, "int8_test_accuracy": accuracy,
        "weight_bytes": int(weights["w1"].nbytes + weights["w2"].nbytes),
        "bias_bytes": int(weights["b1"].nbytes + weights["b2"].nbytes),
        "dataset": BASE_URL, "dataset_md5": FILES,
        "model_sha256": hashlib.sha256((ROOT / "digit_model.npz").read_bytes()).hexdigest(),
    }
    (ROOT / "metrics.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--seed", type=int, default=2026)
    parser.add_argument("--cache", type=Path, default=ROOT / "cache")
    args = parser.parse_args()
    np.random.seed(args.seed)
    train_images, train_labels, test_images, test_labels = load_mnist(args.cache)
    inputs = train_images.reshape(-1, 256).astype(np.float32) / 128
    test_inputs = test_images.reshape(-1, 256).astype(np.float32) / 128
    model = MLPClassifier(hidden_layer_sizes=(32,), batch_size=256, learning_rate_init=0.002,
                          random_state=args.seed, max_iter=1)
    with threadpool_limits(limits=4):
        for epoch in range(args.epochs):
            model.partial_fit(inputs, train_labels, classes=np.arange(10))
            np.clip(model.coefs_[0], -0.99, 0.99, out=model.coefs_[0])
            np.clip(model.coefs_[1], -1.98, 1.98, out=model.coefs_[1])
            accuracy = float((model.predict(test_inputs) == test_labels).mean())
            print(f"Epoch {epoch + 1}/{args.epochs}: float test accuracy {accuracy:.4%}", flush=True)
    export(model, test_images, test_labels, accuracy, args.epochs, args.seed)


if __name__ == "__main__":
    main()
