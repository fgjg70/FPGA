import argparse
import re
import sys
import time


STATUS = re.compile(rb"\[MES50HP\] KEY=[^\r\n]*\r\n")


def collect(port, seconds):
    deadline = time.monotonic() + seconds
    received = bytearray()
    while time.monotonic() < deadline:
        received.extend(port.read(max(1, port.in_waiting)))
    return bytes(received)


def query_status(port):
    port.write(b"?")
    port.flush()
    deadline = time.monotonic() + 2
    received = bytearray()
    while time.monotonic() < deadline:
        received.extend(port.read(max(1, port.in_waiting)))
        matches = list(STATUS.finditer(received))
        if matches:
            return matches[-1].group().decode("ascii").strip()
    raise RuntimeError("No MES50HP status received. Check the debug bitstream, COM port and 115200 8N1 settings.")


def main():
    parser = argparse.ArgumentParser(description="MES50HP UART echo test and six-key status monitor")
    parser.add_argument("--port", help="CP2102 serial port, for example COM5")
    parser.add_argument("--list", action="store_true", help="List available serial ports")
    parser.add_argument("--watch", action="store_true", help="Keep displaying key, UART and HDMI status")
    args = parser.parse_args()
    try:
        import serial
        from serial.tools import list_ports
    except ImportError:
        parser.error("Install pyserial first: python -m pip install pyserial")
    if args.list:
        for entry in list_ports.comports():
            print(f"{entry.device}: {entry.description}")
        return
    if not args.port:
        parser.error("Specify --port COMx, or use --list to find the CP2102 port")
    with serial.Serial(args.port, 115200, bytesize=8, parity="N", stopbits=1,
                       timeout=0.05, write_timeout=2, xonxoff=False, rtscts=False, dsrdtr=False) as port:
        collect(port, 0.3)
        print(query_status(port))
        collect(port, 0.1)
        payload = b"UART_LOOPBACK_" + bytes(65 + index % 26 for index in range(512)) + b"\r\n"
        port.write(payload)
        port.flush()
        response = collect(port, 1)
        echoed = STATUS.sub(b"", response)
        if payload not in echoed:
            raise RuntimeError(f"UART echo mismatch: sent {len(payload)} bytes, received {len(echoed)} echo bytes")
        print(f"PASS UART: {len(payload)} bytes echoed at 115200 8N1")
        status = query_status(port)
        print(status)
        if "FIFO=0" not in status or "FRAME=0" not in status:
            raise RuntimeError("FPGA reported a UART error. Send lowercase c to clear errors and retry.")
        if "HDMI=OK" not in status or "VIDEO=OK" not in status:
            raise RuntimeError("UART passed; FPGA reports an HDMI configuration or pixel clock fault")
        print("PASS FPGA diagnostics: MS7210 acknowledged initialization and pixel clock is running")
        if args.watch:
            print("Press KEY2 through KEY7. KEY bit 0 is KEY2, bit 5 is KEY7. Ctrl+C exits.")
            while True:
                print(query_status(port), flush=True)
                collect(port, 0.5)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("Stopped")
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
