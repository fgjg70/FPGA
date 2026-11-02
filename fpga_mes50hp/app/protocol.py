import struct
import time


MAGIC = b"PG"
VERSION = 2
INFER_COMMANDS = {"software": 2, "hardware": 3, "compare": 4}
MODES = {"hardware": 0, "software": 1, "compare": 2}
STATUS = {1: "Invalid packet or pixel range", 2: "Unsupported command or length",
          3: "Accelerator unavailable or timed out", 4: "Software/hardware logits differ",
          5: "Blank input: draw a digit first", 6: "Recognition expired or already confirmed",
          8: "Configuration updated in RAM; EEPROM save failed",
          9: "UART framing error or receive overflow"}


class BoardError(RuntimeError):
    def __init__(self, status, result=None):
        super().__init__(STATUS.get(status, f"Board error {status}"))
        self.status = status
        self.result = result or {"status": status}


def crc16(data):
    checksum = 0xFFFF
    for value in data:
        checksum ^= value << 8
        for bit_index in range(8):
            checksum = ((checksum << 1) ^ (0x1021 if checksum & 0x8000 else 0)) & 0xFFFF
    return checksum


def frame(command, sequence, payload=b""):
    if len(payload) > 256:
        raise ValueError("Payload exceeds 256 bytes")
    body = struct.pack("<BBH", command, sequence, len(payload)) + payload
    return MAGIC + body + struct.pack("<H", crc16(body))


def read_frame(read, deadline):
    def exact(count):
        result = bytearray()
        while len(result) < count:
            if time.monotonic() >= deadline:
                raise TimeoutError("Board response timed out; check bitstream, COM port and KEY1 reset")
            result.extend(read(count - len(result)))
        return bytes(result)
    matched = False
    while True:
        value = exact(1)
        if matched and value == b"G":
            break
        matched = value == b"P"
    header = exact(4)
    command, sequence, length = struct.unpack("<BBH", header)
    if length > 256:
        raise ValueError("Invalid response length")
    payload = exact(length)
    checksum = struct.unpack("<H", exact(2))[0]
    if checksum != crc16(header + payload):
        raise ValueError("Board response CRC mismatch")
    return command, sequence, payload


def timings(software, hardware, accelerator, clock_hz):
    return {"software_cycles": software, "hardware_cycles": hardware, "accelerator_cycles": accelerator,
            "clock_hz": clock_hz, "software_ms": software * 1000 / clock_hz,
            "hardware_ms": hardware * 1000 / clock_hz,
            "speedup": software / hardware if software and hardware else None}


def parse_result(payload, clock_hz=50000000):
    if not payload:
        raise ValueError("Empty response")
    if len(payload) == 1 and payload[0]:
        raise BoardError(payload[0])
    if len(payload) not in (24, 60, 64):
        raise ValueError("Invalid inference response size")
    status, digit, door, count, software, hardware, accelerator, mismatch = struct.unpack_from("<BBBBIIII", payload)
    result = {"status": status, "digit": digit, "unlocked": bool(door & 1), "alarm": bool(door & 2),
              "pin_count": count, "mismatch": mismatch, **timings(software, hardware, accelerator, clock_hz)}
    if len(payload) >= 60:
        result["logits"] = list(struct.unpack_from("<10i", payload, 20))
    token = struct.unpack_from("<I", payload, len(payload) - 4)[0] if len(payload) != 60 else 0
    result.update(token=token, candidate_valid=bool(token))
    if status:
        raise BoardError(status, result)
    return result


def parse_status(payload, clock_hz=50000000):
    if len(payload) != 40:
        if len(payload) == 1 and payload[0]:
            raise BoardError(payload[0])
        raise ValueError("Invalid board status size")
    status, door, count, candidate, digit, mode, flags, busy, remaining, token, software, hardware, accelerator, overrun, framing, generation = struct.unpack("<8B8I", payload)
    if status:
        raise BoardError(status)
    if mode > 2 or count > 3 or candidate > 1 or busy > 1:
        raise ValueError("Invalid board status fields")
    return {"unlocked": bool(door & 1), "alarm": bool(door & 2), "pin_count": count,
            "candidate_valid": bool(candidate), "digit": digit if digit < 10 else None,
            "mode": tuple(MODES)[mode], "busy": bool(busy), "remaining_ms": remaining, "token": token,
            "eeprom_present": bool(flags & 1), "configuration_saved": bool(flags & 2),
            "configuration_error": bool(flags & 4), "hdmi_initialized": bool(flags & 8),
            "save_pending": bool(flags & 16), "image_valid": bool(flags & 32),
            "uart_overrun": overrun, "uart_framing": framing, "configuration_generation": generation,
            **timings(software, hardware, accelerator, clock_hz)}


class Board:
    def __init__(self, port, timeout=5):
        import serial
        self.serial = serial.Serial(port, 115200, timeout=0.05, write_timeout=2, rtscts=False, dsrdtr=False)
        self.timeout = timeout
        self.sequence = 0
        self.clock_hz = 50000000

    def close(self):
        self.serial.close()

    def transact(self, command, payload=b""):
        self.sequence = (self.sequence + 1) & 255
        packet = frame(command, self.sequence, payload)
        if self.serial.write(packet) != len(packet):
            raise TimeoutError("Serial command was only partly transmitted")
        self.serial.flush()
        deadline = time.monotonic() + self.timeout
        while True:
            received_command, sequence, response = read_frame(self.serial.read, deadline)
            if sequence == self.sequence and received_command == command | 0x80:
                return response

    def hello(self):
        response = self.transact(1)
        if len(response) != 10:
            raise ValueError("Unexpected board identity response")
        status, version, clock_hz, accelerator_id = struct.unpack("<BBII", response)
        if status or version != VERSION or accelerator_id != 0x474D0101 or not clock_hz:
            raise ValueError("Load the digit v2 peripheral bitstream and press KEY1")
        self.clock_hz = clock_hz
        return {"protocol": version, "clock_hz": clock_hz, "accelerator_id": f"{accelerator_id:08x}"}

    def infer(self, pixels, mode="compare", detailed=True):
        data = bytes(pixels)
        if len(data) != 256 or any(value > 127 for value in data):
            raise ValueError("Expected 256 pixels in range 0..127")
        command = INFER_COMMANDS[mode] + (0 if detailed else 16)
        return parse_result(self.transact(command, data), self.clock_hz)

    def status(self):
        return parse_status(self.transact(7), self.clock_hz)

    def diagnostics(self):
        payload = self.transact(15)
        if len(payload) != 84 or payload[0]:
            raise ValueError("Invalid diagnostic response")
        return {"software_valid": bool(payload[1]), "hardware_valid": bool(payload[2]),
                "software_logits": list(struct.unpack_from("<10i", payload, 4)),
                "hardware_logits": list(struct.unpack_from("<10i", payload, 44))}

    def acknowledge(self, command, payload=b""):
        response = self.transact(command, payload)
        if not response:
            raise ValueError("Empty command acknowledgement")
        if response[0]:
            raise BoardError(response[0])
        if response != b"\0":
            raise ValueError("Invalid command acknowledgement")

    def lock(self):
        self.acknowledge(5)
        return self.status()

    def confirm(self, token):
        if not token:
            raise ValueError("Recognize a digit before confirming")
        self.acknowledge(8, struct.pack("<I", token))
        return self.status()

    def cancel(self):
        self.acknowledge(9)
        return self.status()

    def clear(self):
        self.acknowledge(11)
        return self.status()

    def set_pin(self, pin):
        if len(pin) != 4 or any(character not in "0123456789" for character in pin):
            raise ValueError("PIN must contain four decimal digits")
        self.acknowledge(6, bytes(int(character) for character in pin))
        return self.status()

    def set_mode(self, mode):
        self.acknowledge(10, bytes([MODES[mode]]))
        return self.status()

    def set_unlock_ms(self, milliseconds):
        if not 1000 <= milliseconds <= 30000:
            raise ValueError("Unlock duration must be 1000..30000 ms")
        self.acknowledge(14, struct.pack("<I", milliseconds))
        return self.status()

    def restore_defaults(self):
        self.acknowledge(12, b"RST!")
        return self.status()
