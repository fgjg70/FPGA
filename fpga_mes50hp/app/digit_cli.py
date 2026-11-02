import argparse
import json
from pathlib import Path

from PIL import Image

from inference import LocalModel, ROOT, prepare_image
from protocol import Board, BoardError


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port")
    parser.add_argument("--mode", choices=["software", "hardware", "compare"], default="compare")
    parser.add_argument("--offline", action="store_true")
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument("--sample", type=int, choices=range(10))
    actions.add_argument("--image", type=Path)
    actions.add_argument("--lock", action="store_true")
    actions.add_argument("--set-pin")
    actions.add_argument("--hello", action="store_true")
    actions.add_argument("--status", action="store_true")
    actions.add_argument("--confirm", type=int)
    actions.add_argument("--cancel", action="store_true")
    actions.add_argument("--clear", action="store_true")
    actions.add_argument("--set-mode", choices=["hardware", "software", "compare"])
    actions.add_argument("--set-unlock-ms", type=int)
    actions.add_argument("--restore-defaults", action="store_true")
    parser.add_argument("--compact", action="store_true")
    args = parser.parse_args()
    if args.sample is not None:
        samples = json.loads((ROOT / "model/samples.json").read_text(encoding="utf-8"))
        pixels = samples["images"][args.sample]
    elif args.image:
        with Image.open(args.image) as image:
            pixels = prepare_image(image)
    if args.offline:
        if args.sample is None and not args.image:
            parser.error("Offline mode requires --sample or --image")
        print(json.dumps(LocalModel().infer(pixels), indent=2))
        return
    if not args.port:
        parser.error("Specify --port COM5, or use --offline for local preview")
    board = Board(args.port)
    try:
        identity = board.hello()
        if args.hello:
            result = identity
        elif args.lock:
            result = board.lock()
        elif args.set_pin:
            result = board.set_pin(args.set_pin)
        elif args.status:
            result = board.status()
        elif args.confirm is not None:
            result = board.confirm(args.confirm)
        elif args.cancel:
            result = board.cancel()
        elif args.clear:
            result = board.clear()
        elif args.set_mode:
            result = board.set_mode(args.set_mode)
        elif args.set_unlock_ms is not None:
            result = board.set_unlock_ms(args.set_unlock_ms)
        elif args.restore_defaults:
            result = board.restore_defaults()
        else:
            result = board.infer(pixels, args.mode, detailed=not args.compact)
        print(json.dumps(result, indent=2))
    except BoardError as error:
        print(json.dumps({"error": str(error), **error.result}, indent=2))
        raise SystemExit(1)
    finally:
        board.close()


if __name__ == "__main__":
    main()
