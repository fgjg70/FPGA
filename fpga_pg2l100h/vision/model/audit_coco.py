import argparse
import hashlib
import importlib
import json
from pathlib import Path
import sys
import zipfile

import torch
import torch.nn as nn


ROOT = Path(__file__).resolve().parent
REVISION = "ac2a5e3060bff76dd1e45f9b921dd77bfbeb194d"
WEIGHT_SHA256 = "bdd956aa079bf1cdd3e0090a295ac26d73c40aef7b61b6405981b1afcbea985c"
SOURCE_FILES = ["model/detector.py", "model/fpn.py", "model/backbone/shufflenetv2.py", "data/coco.names", "data/coco.data", "README.md"]


def tensor_bytes(value):
    if isinstance(value, torch.Tensor):
        return value.numel()
    if isinstance(value, (list, tuple)):
        return sum(tensor_bytes(item) for item in value)
    return 0


def profile(model, size):
    layers = []
    handles = []

    def hook(name):
        def record(module, inputs, output):
            entry = dict(name=name, operation=type(module).__name__, input_shapes=[list(value.shape) for value in inputs], output_shape=list(output.shape),
                         int8_input_output_bytes=tensor_bytes(inputs) + tensor_bytes(output))
            if isinstance(module, nn.Conv2d):
                entry.update(kernel=list(module.kernel_size), stride=list(module.stride), groups=module.groups,
                             input_channels=module.in_channels, output_channels=module.out_channels,
                             macs=output.numel() * module.in_channels // module.groups * module.kernel_size[0] * module.kernel_size[1])
            layers.append(entry)
        return record

    for name, module in model.named_modules():
        if isinstance(module, (nn.Conv2d, nn.MaxPool2d)):
            handles.append(module.register_forward_hook(hook(name)))
    torch.manual_seed(12550)
    with torch.inference_mode():
        output = model(torch.rand(1, 3, size, size))
    for handle in handles:
        handle.remove()
    assert len(output) == 6 and output[2].shape[1] == output[5].shape[1] == 80
    largest = max(layers, key=lambda entry: entry["int8_input_output_bytes"])
    macs = sum(entry.get("macs", 0) for entry in layers)
    return dict(input=[1, 3, size, size], output_shapes=[list(value.shape) for value in output],
                strict_checkpoint_forward_pass=True, accuracy_measured=False,
                convolution_calls=sum(entry["operation"] == "Conv2d" for entry in layers), macs=macs,
                hypothetical_single_mac_seconds_at_50mhz=2 * macs / 50000000,
                hypothetical_single_mac_scope="Two cycles per MAC only; excludes all memory, graph operations, requantization and CPU postprocessing. Current RTL cannot execute this graph.",
                largest_unfused_operator_int8_input_output_bytes=largest["int8_input_output_bytes"],
                largest_unfused_operator=largest["name"], layers=layers)


def main():
    parser = argparse.ArgumentParser(description="Audit the exact cached COCO-80 checkpoint against FPGA resources; does not export deployable FPGA weights")
    parser.add_argument("--output", type=Path, default=ROOT.parent / "validation/coco_architecture")
    parser.add_argument("--sizes", type=int, nargs="+", default=[128, 160, 352])
    args = parser.parse_args()
    if any(size < 32 or size % 32 for size in args.sizes):
        raise ValueError("Input dimensions must be positive multiples of 32")
    weights = ROOT / "checkpoints/pretrained/yolo_fastestv2_coco.pth"
    if hashlib.sha256(weights.read_bytes()).hexdigest() != WEIGHT_SHA256:
        raise ValueError("Reference checkpoint SHA-256 mismatch")
    archive_path = ROOT / "checkpoints/public_cache/yolo_fastestv2.zip"
    reference = args.output / "reference"
    source_hashes = {}
    with zipfile.ZipFile(archive_path) as archive:
        archive_revision = archive.comment.decode("ascii", errors="replace")
        for relative in SOURCE_FILES:
            matches = [name for name in archive.namelist() if name.split("/", 1)[-1] == relative]
            if len(matches) != 1 or (archive_revision != REVISION and REVISION not in matches[0].split("/")[0]):
                raise ValueError("Reference source revision or file mismatch: " + relative)
            contents = archive.read(matches[0])
            source_hashes[relative] = hashlib.sha256(contents).hexdigest()
            if relative.endswith("shufflenetv2.py"):
                contents = contents.replace(b"from torchsummary import summary\n", b"")
            target = reference / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(contents)
    sys.path.insert(0, str(reference))
    detector = importlib.import_module("model.detector")
    model = detector.Detector(80, 3, True).eval()
    checkpoint = torch.load(weights, map_location="cpu", weights_only=True)
    model.load_state_dict(checkpoint, strict=True)
    classes = (reference / "data/coco.names").read_text().splitlines()
    assert len(classes) == 80
    convolutions = [module for module in model.modules() if isinstance(module, nn.Conv2d)]
    fused_weights = sum(module.weight.numel() for module in convolutions)
    fused_bias_bytes = 4 * sum(module.out_channels for module in convolutions)
    profiles = [profile(model, size) for size in args.sizes]
    report = dict(
        repository="dog-qiuqiu/Yolo-FastestV2", revision=REVISION, checkpoint_sha256=WEIGHT_SHA256,
        source_sha256=source_hashes, source_adaptation="Removed unused torchsummary import only; Detector(load_param=True) avoids loading a separate backbone checkpoint.",
        checkpoint_loaded_strictly=True, checkpoint_tensor_count=len(checkpoint),
        trainable_parameters=sum(parameter.numel() for parameter in model.parameters()),
        hypothetical_fused_int8_convolution_weight_bytes=fused_weights, hypothetical_fused_int32_bias_bytes=fused_bias_bytes,
        quantization_calibrated=False, model_accuracy_measured=False, fpga_compatible=False, hardware_recognition_verified=False,
        classes=classes, class_count=len(classes),
        required_operations=["RGB input", "normal 1x1/3x3 convolution", "depthwise 3x3/5x5 convolution", "BatchNorm fusion and signed requantization", "ReLU", "3x3 max pooling", "channel shuffle and split", "concatenation", "nearest-neighbor 2x upsampling", "two-scale anchor heads", "sigmoid, class softmax, box decoding and NMS"],
        current_rtl_limits=dict(input=[64, 64, 1], convolution_layers=6, output_channels=27, class_slots=22, class_id_bits=6, coherent_display_payload_bits=272, largest_kernel=3, grouped_convolution=False, graph_shuffle_concat_upsample=False, weight_rom_capacity_bytes=65536),
        pg2l100h_drm_count=155, drm_bits_per_block=36864, theoretical_total_drm_bytes=155 * 36864 // 8,
        memory_scope="Theoretical raw block capacity, before width/depth rounding, banking, frame buffers, CPU, firmware, biases, outputs and activation liveness. Unfused operator numbers are scheduling estimates, not a lower bound for a streaming redesign.",
        profiles=profiles,
        conclusion="The original 80-class checkpoint executes correctly on the host. Loading it into the fixed six-layer FPGA accelerator is unsupported. Full-resolution frame-based execution exceeds on-chip activation storage; smaller inputs still require a new grouped-convolution graph engine, RGB preprocessing, calibrated INT8 export and new postprocessing. DDR or a measured streaming/tiled memory design must be implemented before board deployment.",
    )
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "audit.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"PASS COCO reference: strict checkpoint load, {len(classes)} classes, {report['trainable_parameters']} parameters; hypothetical fused INT8 weights={fused_weights} bytes")
    for entry in profiles:
        print(f"{entry['input'][2]}x{entry['input'][3]}: {entry['macs']} MACs, largest unfused INT8 input+output={entry['largest_unfused_operator_int8_input_output_bytes']} bytes")
    print("FPGA deployment remains unsupported; audit is a host reference and resource estimate.")


if __name__ == "__main__":
    main()
