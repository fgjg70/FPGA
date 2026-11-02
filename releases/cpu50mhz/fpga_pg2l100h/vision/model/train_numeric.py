import argparse
import hashlib
import json
from pathlib import Path
import time

import numpy as np
from PIL import Image, ImageDraw, ImageFont
import torch
from torch.nn import functional

from network import MicroYolo, decode, export_arrays, integer_forward
from train import ROOT, loss_value, make_batch, mnist, write_model
from train_public import evaluate, save_vectors


TRAIN_FONTS = ["arial.ttf", "arialbd.ttf", "calibri.ttf", "calibrib.ttf", "consola.ttf", "consolab.ttf", "cour.ttf", "courbd.ttf", "tahoma.ttf", "tahomabd.ttf"]
TEST_FONTS = ["georgia.ttf", "times.ttf", "verdana.ttf", "trebuc.ttf"]
CLASS_MARGIN = 24
EMPTY_THRESHOLD = 40


def glyphs(font_dir, names, text="0123456789"):
    images = []
    labels = []
    provenance = []
    for name in names:
        path = font_dir / name
        font = ImageFont.truetype(str(path), 72)
        provenance.append(dict(name=name, sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
        for character in text:
            image = Image.new("L", (128, 128))
            draw = ImageDraw.Draw(image)
            draw.text((20, 0), character, font=font, fill=255)
            cropped = image.crop(image.getbbox())
            cropped.thumbnail((22, 24), Image.Resampling.LANCZOS)
            canvas = Image.new("L", (28, 28))
            canvas.paste(cropped, ((28 - cropped.width) // 2, (28 - cropped.height) // 2))
            images.append(np.asarray(canvas, dtype=np.float32) / 255)
            labels.append(int(character) if character.isdigit() else 0)
    return torch.from_numpy(np.stack(images)[:, None]), torch.tensor(labels), provenance


def batch(images, labels, printed, printed_labels, negatives, count, generator, evaluation=False, mode="mixed", negative_ratio=0.15, printed_ratio=0.5):
    pixels, targets = make_batch(images, labels, count, generator, evaluation)
    printed_pixels, printed_targets = make_batch(printed, printed_labels, count, generator, evaluation)
    choose_printed = torch.rand(count, generator=generator) < printed_ratio
    if mode == "printed":
        choose_printed[:] = True
    if mode == "handwritten":
        choose_printed[:] = False
    pixels[choose_printed] = printed_pixels[choose_printed]
    for name in targets:
        targets[name][choose_printed] = printed_targets[name][choose_printed]
    if mode == "negative":
        targets["present"][:] = False
    elif not evaluation and negative_ratio > 0.15:
        targets["present"][torch.rand(count, generator=generator) < (negative_ratio - 0.15) / 0.85] = False
    negative_pixels, _ = make_batch(negatives, torch.zeros(len(negatives), dtype=torch.long), count, generator, evaluation)
    hard = ~targets["present"] & (torch.rand(count, generator=generator) < 0.75)
    pixels[~targets["present"]] = 0
    pixels[hard] = negative_pixels[hard]
    gradient = torch.linspace(0, 1, 64)[None, None, None, :]
    pixels += torch.rand((count, 1, 1, 1), generator=generator) * 0.08 * gradient
    blur = torch.rand(count, generator=generator) < 0.25
    pixels[blur] = functional.avg_pool2d(pixels[blur], 3, stride=1, padding=1)
    pixels = pixels.clamp(0, 127 / 128).mul(128).round().div(128)
    pixels[:, :, :2] = 0
    pixels[:, :, 62:] = 0
    return pixels, targets


def gated_metrics(pixels, targets, arrays):
    metrics = dict(positive_samples=int(targets["present"].sum()), negative_samples=int((~targets["present"]).sum()), accepted_correct=0, accepted_wrong=0, rejected_positive=0, negative_accepted=0, negative_confirmed_empty=0)
    for start in range(0, len(pixels), 32):
        outputs = integer_forward(np.rint(pixels[start:start + 32, 0].numpy() * 128).astype(np.uint8), arrays)
        for offset, output in enumerate(outputs):
            index = start + offset
            cell = output.reshape(16, 27)[int(np.argmax(output[:, :, 0]))]
            ranked = sorted(map(int, cell[17:27]), reverse=True)
            accepted = int(cell[0]) >= 72 and ranked[0] - ranked[1] >= CLASS_MARGIN
            if targets["present"][index]:
                if not accepted:
                    metrics["rejected_positive"] += 1
                elif 12 + int(np.argmax(cell[17:27])) == int(targets["category"][index]):
                    metrics["accepted_correct"] += 1
                else:
                    metrics["accepted_wrong"] += 1
            else:
                metrics["negative_accepted"] += int(accepted)
                metrics["negative_confirmed_empty"] += int(cell[0]) < EMPTY_THRESHOLD
    return metrics


def main():
    parser = argparse.ArgumentParser(description="Train the focused numeric-label verifier; held-out fonts and MNIST test remain evaluation-only")
    parser.add_argument("--steps", type=int, default=7000)
    parser.add_argument("--batch-size", type=int, default=96)
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--seed", type=int, default=20261101)
    parser.add_argument("--font-dir", type=Path, default=Path("C:/Windows/Fonts"))
    parser.add_argument("--output", type=Path, default=ROOT / "model/candidates/numeric_labels")
    parser.add_argument("--init", type=Path, default=ROOT / "model/baselines/digits/micro_yolo.npz")
    parser.add_argument("--evaluate-only", action="store_true")
    parser.add_argument("--negative-ratio", type=float, default=0.15)
    parser.add_argument("--printed-ratio", type=float, default=0.5)
    parser.add_argument("--background-penalty", type=float, default=1.0)
    parser.add_argument("--background-reduction", choices=["mean", "peak"], default="peak")
    args = parser.parse_args()
    if not 0.15 <= args.negative_ratio < 0.9 or not 0 <= args.printed_ratio <= 1:
        parser.error("negative ratio must be in [0.15,0.9), printed ratio in [0,1]")
    torch.set_num_threads(args.threads)
    torch.manual_seed(args.seed)
    generator = torch.Generator().manual_seed(args.seed)
    images, labels = mnist("train")
    test_images, test_labels = mnist("test")
    printed, printed_labels, training_fonts = glyphs(args.font_dir, TRAIN_FONTS)
    test_printed, test_printed_labels, test_fonts = glyphs(args.font_dir, TEST_FONTS)
    negatives, _, _ = glyphs(args.font_dir, TRAIN_FONTS, "AFKMNRTWXYZ+-=*")
    test_negatives, _, _ = glyphs(args.font_dir, TEST_FONTS, "AFKMNRTWXYZ+-=*")
    network = MicroYolo()
    with np.load(args.init, allow_pickle=False) as arrays, torch.no_grad():
        for index, layer in enumerate(network.layers):
            scale = 2 ** int(arrays[f"shift_{index}"])
            layer.weight.copy_(torch.from_numpy(arrays[f"weight_{index}"].astype(np.float32) / scale))
            layer.bias.copy_(torch.from_numpy(arrays[f"bias_{index}"].astype(np.float32) / (scale * 128)))
    optimizer = torch.optim.Adam(network.parameters(), lr=0.0006)
    args.output.mkdir(parents=True, exist_ok=True)
    checkpoint = args.output / "training_checkpoint.pt"
    if args.evaluate_only:
        network.load_state_dict(torch.load(checkpoint, weights_only=True, map_location="cpu"))
    started = time.time()
    for step in range(0 if args.evaluate_only else args.steps):
        pixels, targets = batch(images, labels, printed, printed_labels, negatives, args.batch_size, generator, negative_ratio=args.negative_ratio, printed_ratio=args.printed_ratio)
        optimizer.zero_grad(set_to_none=True)
        output = network(pixels)
        loss = loss_value(output, targets, class_weight=0.45)
        absent = ~targets["present"]
        if absent.any():
            background = output[absent, 0].flatten(1)
            penalty = background.square().mean() if args.background_reduction == "mean" else background.amax(1).square().mean()
            loss = loss + args.background_penalty * penalty
        loss.backward()
        optimizer.step()
        if step == args.steps * 3 // 4:
            for group in optimizer.param_groups:
                group["lr"] = 0.00015
        if step % 500 == 0 or step + 1 == args.steps:
            print(json.dumps(dict(step=step + 1, loss=round(float(loss.detach()), 5), elapsed_seconds=round(time.time() - started, 1))), flush=True)
    torch.save(network.state_dict(), checkpoint)
    arrays = export_arrays(network)
    reports = {}
    vector_pixels = []
    vector_candidates = []
    for index, mode in enumerate(["printed", "handwritten", "negative"]):
        pixels, targets = batch(test_images, test_labels, test_printed, test_printed_labels, test_negatives, 512, torch.Generator().manual_seed(args.seed + index + 1), evaluation=True, mode=mode)
        metrics, _, candidates = evaluate(network, pixels, targets, list(range(12, 22)))
        metrics["quality_gate"] = gated_metrics(pixels, targets, arrays)
        reports[mode] = metrics
        if mode != "negative":
            vector_pixels.append(pixels)
            vector_candidates.extend(candidates)
        print(json.dumps(dict(domain=mode, positives=int(targets["present"].sum()), correct_iou50=metrics["correct_class_and_iou50"], quality_gate=metrics["quality_gate"])), flush=True)
    metadata = dict(project="NUMGUARD numeric material-bin label verifier", seed=args.seed, steps=args.steps,
                    negative_training_ratio=args.negative_ratio, printed_training_ratio=args.printed_ratio, background_penalty=args.background_penalty,
                    background_reduction=args.background_reduction,
                    train_source="MNIST train and rendered training-font digits; independent affine, blur, gain, gradient, noise and letter/symbol negatives",
                    training_fonts=training_fonts, validation_fonts=test_fonts,
                    validation_source="MNIST test and four held-out fonts; synthetic camera preprocessing, no real camera images",
                    negative_generator_revision=2,
                    validation_domains=reports, class_margin_threshold=CLASS_MARGIN, empty_threshold=EMPTY_THRESHOLD,
                    supported_domain="one dark digit 0-9 on a light plain label in the central camera region; letters are not supported",
                    limitations=["No physical camera validation", "Synthetic font split is not an industrial dataset", "Repeated-frame voting does not make systematic classification errors independent", "Letter O versus digit zero and I versus one require constrained label format"],
                    initialization_sha256=hashlib.sha256(args.init.read_bytes()).hexdigest(),
                    elapsed_seconds=round(time.time() - started, 2))
    write_model(network, metadata, list(range(12, 22)), args.output)
    save_vectors(args.output / "vectors", torch.cat(vector_pixels), arrays, vector_candidates)
    (args.output / "training_report.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(dict(output=str(args.output), elapsed_seconds=round(time.time() - started, 1))), flush=True)


if __name__ == "__main__":
    main()
