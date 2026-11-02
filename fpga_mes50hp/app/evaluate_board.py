import argparse
import csv
import gzip
import hashlib
import json
from pathlib import Path
import time

import numpy as np
from PIL import Image

from inference import LocalModel, ROOT, prepare_image
from preprocessing import VERSION
from protocol import Board, BoardError


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True)
    parser.add_argument("--cache", type=Path, default=ROOT / "model/cache")
    parser.add_argument("--count", type=int, default=100)
    parser.add_argument("--offset", type=int, default=0)
    parser.add_argument("--mode", choices=["hardware", "software", "compare"], default="compare")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/board_digits.csv")
    args = parser.parse_args()
    expected = {"t10k-images-idx3-ubyte.gz": "9fb629c4189551a2d022fa330f9573f3",
                "t10k-labels-idx1-ubyte.gz": "ec29112dd5afa0611ce80d1b7f02629c"}
    raw = []
    for filename, checksum in expected.items():
        data = (args.cache / filename).read_bytes()
        if hashlib.md5(data).hexdigest() != checksum:
            raise ValueError("MNIST checksum mismatch: " + filename)
        raw.append(gzip.decompress(data))
    images = np.frombuffer(raw[0], np.uint8, offset=16).reshape(-1, 28, 28)
    labels = np.frombuffer(raw[1], np.uint8, offset=8)
    if args.offset < 0 or args.count < 1 or args.offset + args.count > len(labels):
        parser.error("Requested test range is outside the MNIST test set")
    local = LocalModel()
    board = Board(args.port)
    report = {"mode": args.mode, "offset": args.offset, "requested": args.count, "attempted": 0,
              "valid_predictions": 0, "correct": 0, "logit_mismatches": 0,
              "computation_errors": 0, "communication_errors": 0,
              "preprocessing_version": VERSION, "csv": str(args.output), "source": "physical board UART"}
    confusion = np.zeros((10, 10), dtype=int)
    latencies = []
    connected = False
    consecutive_errors = 0
    args.output.parent.mkdir(parents=True, exist_ok=True)
    fields = ["index", "label", "predicted", "correct", "status", "error", "logit_mismatch",
              "software_cycles", "hardware_cycles", "accelerator_cycles", "preprocess_ms", "roundtrip_ms", "diagnostics"]
    try:
        report["identity"] = board.hello()
        connected = True
        board.lock()
        with args.output.open("w", newline="", encoding="utf-8") as output:
            writer = csv.DictWriter(output, fieldnames=fields)
            writer.writeheader()
            for index in range(args.offset, args.offset + args.count):
                started = time.perf_counter()
                pixels = prepare_image(Image.fromarray(images[index]))
                preprocess_ms = (time.perf_counter() - started) * 1000
                expected_logits = local.infer(pixels)["logits"]
                row = {"index": index, "label": int(labels[index]), "correct": 0, "status": 0,
                       "preprocess_ms": preprocess_ms, "error": ""}
                started = time.perf_counter()
                result = None
                try:
                    result = board.infer(pixels, args.mode)
                    consecutive_errors = 0
                except BoardError as error:
                    result = error.result
                    row.update(status=error.status, error=str(error))
                    if error.status == 4:
                        report["computation_errors"] += 1
                        consecutive_errors = 0
                        try:
                            row["diagnostics"] = json.dumps(board.diagnostics(), separators=(",", ":"))
                        except Exception as diagnostic_error:
                            row["diagnostics"] = json.dumps({"error": str(diagnostic_error)})
                    else:
                        report["communication_errors"] += 1
                        consecutive_errors += 1
                except (OSError, ValueError, TimeoutError) as error:
                    row.update(status=-1, error=str(error))
                    report["communication_errors"] += 1
                    consecutive_errors += 1
                row["roundtrip_ms"] = (time.perf_counter() - started) * 1000
                if result and "logits" in result:
                    mismatch = sum(left != right for left, right in zip(result["logits"], expected_logits))
                    report["logit_mismatches"] += mismatch
                    row.update(predicted=result["digit"], logit_mismatch=mismatch,
                               software_cycles=result["software_cycles"], hardware_cycles=result["hardware_cycles"],
                               accelerator_cycles=result["accelerator_cycles"])
                    if not row["status"] and not mismatch:
                        row["correct"] = int(result["digit"] == int(labels[index]))
                        report["valid_predictions"] += 1
                        report["correct"] += row["correct"]
                        confusion[int(labels[index]), result["digit"]] += 1
                        latencies.append(row["roundtrip_ms"])
                    elif mismatch and not row["status"]:
                        row.update(status=4, error="Board logits differ from Python reference")
                        report["computation_errors"] += 1
                        row["diagnostics"] = json.dumps({"expected_logits": expected_logits, "board_logits": result["logits"]})
                writer.writerow(row)
                output.flush()
                report["attempted"] += 1
                if report["attempted"] % 10 == 0:
                    print(f"{report['attempted']}/{args.count}: correct={report['correct']}, logit_mismatch={report['logit_mismatches']}", flush=True)
                if consecutive_errors >= 3:
                    report["stopped_reason"] = "Three consecutive communication errors"
                    break
    except Exception as error:
        report["fatal_error"] = str(error)
    finally:
        if connected:
            try:
                board.lock()
            except Exception as error:
                report["cleanup_error"] = str(error)
        board.close()
        report["completed"] = report["attempted"] == args.count
        report["accuracy"] = report["correct"] / report["attempted"] if report["attempted"] else None
        report["confusion_matrix"] = confusion.tolist()
        if latencies:
            report["roundtrip_ms"] = {"mean": float(np.mean(latencies)), "median": float(np.median(latencies)),
                                      "p95": float(np.percentile(latencies, 95))}
        args.output.with_suffix(".json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    if not report["completed"] or report["computation_errors"] or report["communication_errors"] or "fatal_error" in report:
        raise SystemExit("Board evaluation contains errors; CSV and partial summary were preserved")


if __name__ == "__main__":
    main()
