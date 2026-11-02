import binascii
import importlib.util
import json
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
build = load("numeric_build", ROOT / "build.py")


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

    def test_northern_ten_capture_and_convention(self):
        data, _ = self.frame_lines()
        with tempfile.TemporaryDirectory(dir=ROOT / "validation", prefix="north_capture_test_") as directory:
            destination = Path(directory)
            name = capture.save_frame(data, destination, "session10", "person10", "train", 10, [12, 10, 52, 50], "hand")
            self.assertEqual((destination / "labels/train" / (name + ".txt")).read_text().split()[0], "9")
            self.assertEqual(json.loads((destination / "classes.json").read_text())[-1], "hand 10")
            metadata = json.loads((destination / "metadata/train" / (name + ".json")).read_text(encoding="utf-8"))
            self.assertEqual(metadata["label"], 10)
            self.assertEqual(metadata["gesture_standard"], capture.STANDARD_ID)
            self.assertIn("双手食指", metadata["pose"])
            for mode, label in [("hand", 0), ("hand", 11), ("label", 10)]:
                with self.assertRaises(ValueError):
                    capture.save_frame(data, destination, "session10", "person10", "train", label, None, mode)
            (destination / "gesture_standard.json").write_text("{}", encoding="utf-8")
            with self.assertRaises(ValueError):
                capture.save_frame(data, destination, "session10", "person10", "train", 1, None, "hand")

    def test_ten_bank_requires_the_crossed_finger_convention(self):
        names = ["people", "bike", "hand 10"] + [f"hand {number}" for number in range(1, 10)] + [f"digit {number}" for number in range(10)]
        model = dict(classes=names, enabled_classes=list(range(2, 12)), input=[64, 64, 1], grid=[4, 4],
                     gesture_standard=capture.STANDARD_ID, gesture_convention=capture.definition(), sha256={})
        with tempfile.TemporaryDirectory(dir=ROOT / "validation", prefix="north_bank_test_") as directory:
            destination = Path(directory)
            path = destination / "model.json"
            path.write_text(json.dumps(model), encoding="utf-8")
            self.assertEqual(len(build.gesture_model(destination)["enabled_classes"]), 10)
            model["gesture_convention"]["gestures"][-1]["pose"] = "fist"
            path.write_text(json.dumps(model), encoding="utf-8")
            with self.assertRaises(ValueError):
                build.gesture_model(destination)
            model["gesture_convention"] = capture.definition()
            model["classes"][2] = "cup"
            path.write_text(json.dumps(model), encoding="utf-8")
            with self.assertRaises(ValueError):
                build.gesture_model(destination)

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

    def test_cpu_and_timer_frequencies_are_independent(self):
        text = "CM64 ticks=000000001dcd6500 clock=50000000 iterations=6000 cpu=125000000\nCorrect operation validated." + self.reference_crcs
        report = benchmark.parse_log(text)
        self.assertTrue(report["eligible"])
        self.assertEqual(report["cpu_clock_hz"], 125000000)
        self.assertAlmostEqual(report["coremark"], 600)
        self.assertAlmostEqual(report["coremark_per_mhz"], 4.8)
        self.assertFalse(benchmark.parse_log(text.replace("cpu=125000000", "cpu=250000000"))["eligible"])


if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ToolTests))
    if result.wasSuccessful():
        print("PASS tools CRC32 frame capture, padding/range checks, physical-session split isolation and valid CoreMark measurement gates")
    sys.exit(0 if result.wasSuccessful() else 1)
