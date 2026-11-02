import argparse
import time


def main():
    parser = argparse.ArgumentParser(description="MES50HP camera/LCD UART status monitor, 115200 8N1")
    parser.add_argument("--port", required=True, help="For example COM5")
    parser.add_argument("--command", choices=["?", "s", "c", "b", "f", "t", "r"], default="?")
    parser.add_argument("--seconds", type=float, default=5)
    args = parser.parse_args()
    try:
        import serial
    except ImportError:
        parser.error("Install pyserial first: python -m pip install pyserial")
    with serial.Serial(args.port, 115200, timeout=0.25, write_timeout=1) as port:
        port.write(args.command.encode("ascii"))
        deadline = time.monotonic() + args.seconds
        while time.monotonic() < deadline:
            record = port.readline()
            if record:
                print(record.decode("ascii", errors="replace").rstrip(), flush=True)


if __name__ == "__main__":
    main()
