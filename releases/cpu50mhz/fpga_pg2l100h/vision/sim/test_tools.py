import binascii
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


capture = load("numeric_capture", ROOT / "tools/capture_numeric.py")
benchmark = load("numeric_coremark", ROOT / "competition/coremark.py")


class ToolTests(unittest.TestCase):
    reference_crcs = "\nseedcrc : 0xe9f5\n[0]crclist : 0xe714\n[0]crcmatrix : 0x1fd7\n[0]crcstate : 0x8e3a\n"
    def frame_lines(self):
        data = bytearray(4096)
        data[1000] = 77
        rows = [bytes(data[index:index + 64]).hex() for index in range(0, 4096, 64)]
        return bytes(data), ["Q7FRAME BEGIN", *rows, f"Q7FRAME END {binascii.crc32(data):08X}"]

    def test_frame_integrity(self):
        data, lines = self.frame_lines()
        self.assertEqual(capture.parse_frame(lines), data)
        for corrupted in [lines[:-2] + lines[-1:], lines[:-1] + ["Q7FRAME END 00000000"], lines[:3] + ["FF" * 64] + lines[4:]]:
            with self.assertRaises(ValueError):
                capture.parse_frame(corrupted)

    def test_gesture_capture_mapping(self):
        data, _ = self.frame_lines()
        with tempfile.TemporaryDirectory(dir=ROOT / "validation", prefix="hand_capture_test_") as directory:
            destination = Path(directory)
            name = capture.save_frame(data, destination, "session1", "person1", "train", 9, [20, 10, 40, 50], "hand")
            self.assertEqual((destination / "labels/train" / (name + ".txt")).read_text().split()[0], "8")
            with self.assertRaises(ValueError):
                capture.save_frame(data, destination, "session1", "person1", "train", 3, None, "label")
            with self.assertRaises(ValueError):
                capture.save_frame(data, destination, "session1", "person1", "train", 0, None, "hand")

    def test_split_protection(self):
        data, _ = self.frame_lines()
        with tempfile.TemporaryDirectory(dir=ROOT / "validation", prefix="capture_test_") as directory:
            destination = Path(directory)
            name = capture.save_frame(data, destination, "session1", "card3", "train", 3, [20, 10, 40, 50])
            self.assertTrue((destination / "labels/train" / (name + ".txt")).is_file())
            with self.assertRaises(ValueError):
                capture.save_frame(data, destination, "session2", "card4", "test", 3, [20, 10, 40, 50])
            with self.assertRaises(ValueError):
                capture.save_frame(data, destination, "../escape", "card3", "train", None, None)

    def test_short_or_bad_crc_is_not_a_score(self):
        short = "CM64 ticks=0000000000000064 clock=50000000 iterations=1\nCorrect operation validated."
        self.assertFalse(benchmark.parse_log(short)["eligible"])
        valid = "CM64 ticks=000000001dcd6500 clock=50000000 iterations=6000\nCorrect operation validated." + self.reference_crcs
        self.assertTrue(benchmark.parse_log(valid)["eligible"])
        self.assertFalse(benchmark.parse_log(valid.replace("Correct operation validated.", "Errors detected"))["eligible"])
        self.assertFalse(benchmark.parse_log(valid.replace("0xe714", "0xe715"))["eligible"])
        with self.assertRaises(ValueError):
            benchmark.parse_log(valid + "\n" + valid)

    def test_full_64_bit_counter_and_frequency(self):
        text = "CM64 ticks=0000000100000001 clock=50000000 iterations=6000\nCorrect operation validated." + self.reference_crcs
        report = benchmark.parse_log(text)
        self.assertEqual(report["ticks"], 4294967297)
        self.assertAlmostEqual(report["coremark_per_mhz"], 6000e6 / 4294967297)
        self.assertFalse(benchmark.parse_log(text.replace("clock=50000000", "clock=27000000"))["eligible"])


if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ToolTests))
    if result.wasSuccessful():
        print("PASS tools CRC32 frame capture, padding/range checks, physical-session split isolation and valid CoreMark measurement gates")
    sys.exit(0 if result.wasSuccessful() else 1)
