import argparse
from collections import deque
from concurrent.futures import ThreadPoolExecutor
import json
import tkinter as tk
from tkinter import messagebox, ttk

from PIL import Image, ImageDraw, ImageTk

from inference import LocalModel, ROOT, prepare_image
from protocol import Board, BoardError


class Demo:
    def __init__(self, root, port=None, offline=False):
        self.root = root
        self.offline = offline
        self.board = None
        self.executor = ThreadPoolExecutor(max_workers=1)
        self.queue = deque()
        self.pending = None
        self.pending_kind = None
        self.closing = False
        self.poll_enabled = False
        self.revision = 0
        self.recognized_revision = None
        self.active_token = 0
        self.previous = None
        self.samples = json.loads((ROOT / "model/samples.json").read_text(encoding="utf-8"))["images"]
        self.sample_pixels = None
        self.local_model = LocalModel() if offline else None
        self.controls = []
        root.title("MES50HP | RISC-V Digit Terminal v2")
        root.resizable(False, False)
        container = ttk.Frame(root, padding=18)
        container.grid()
        ttk.Label(container, text="RISC-V Handwritten PIN Terminal", font=("Segoe UI", 18, "bold")).grid(row=0, column=0, columnspan=3, pady=(0, 12))
        self.port = tk.StringVar(value=port or "")
        self.mode = tk.StringVar(value="hardware")
        self.pin = tk.StringVar(value="1234")
        self.unlock_ms = tk.StringVar(value="5000")
        if not offline:
            from serial.tools import list_ports
            ports = [entry.device for entry in list_ports.comports()]
            if not port and ports:
                self.port.set(ports[0])
            ttk.Combobox(container, textvariable=self.port, values=ports, width=15).grid(row=1, column=0, sticky="w")
            self.connect_button = ttk.Button(container, text="Connect", command=self.connect)
            self.connect_button.grid(row=1, column=1, sticky="w")
            self.controls.append(self.connect_button)
        else:
            ttk.Label(container, text="LOCAL PREVIEW | inference runs on this PC").grid(row=1, column=0, columnspan=3, sticky="w")
        self.canvas = tk.Canvas(container, width=280, height=280, bg="black", highlightthickness=1)
        self.canvas.grid(row=2, column=0, columnspan=2, pady=12)
        self.canvas.bind("<Button-1>", self.start_stroke)
        self.canvas.bind("<B1-Motion>", self.draw_stroke)
        self.canvas.bind("<ButtonRelease-1>", lambda event: setattr(self, "previous", None))
        self.image = Image.new("L", (280, 280))
        self.draw = ImageDraw.Draw(self.image)
        self.preview = ttk.Label(container)
        self.preview.grid(row=2, column=2, padx=18)
        self.mode_box = ttk.Combobox(container, textvariable=self.mode, values=["hardware", "software", "compare"], state="readonly", width=15)
        self.mode_box.grid(row=3, column=0, sticky="w")
        self.mode_box.bind("<<ComboboxSelected>>", lambda event: self.board_action("mode"))
        self.infer_button = ttk.Button(container, text="Recognize", command=self.recognize)
        self.infer_button.grid(row=3, column=1, sticky="w")
        self.controls.append(self.infer_button)
        self.confirm_button = ttk.Button(container, text="Confirm digit", command=lambda: self.board_action("confirm"), state="disabled")
        self.confirm_button.grid(row=3, column=2, sticky="w")
        sample_bar = ttk.Frame(container)
        sample_bar.grid(row=4, column=0, columnspan=3, sticky="w", pady=10)
        self.sample = tk.StringVar(value="0")
        ttk.Label(sample_bar, text="MNIST sample:").pack(side="left")
        ttk.Combobox(sample_bar, textvariable=self.sample, values=list(range(10)), state="readonly", width=3).pack(side="left", padx=8)
        for label, action in [("Load", self.load_sample), ("Clear", self.clear), ("Undo", lambda: self.board_action("cancel"))]:
            button = ttk.Button(sample_bar, text=label, command=action)
            button.pack(side="left", padx=3)
            self.controls.append(button)
        control_bar = ttk.Frame(container)
        control_bar.grid(row=5, column=0, columnspan=3, sticky="w", pady=5)
        ttk.Label(control_bar, text="New PIN:").pack(side="left")
        ttk.Entry(control_bar, textvariable=self.pin, width=6).pack(side="left", padx=6)
        pin_button = ttk.Button(control_bar, text="Save PIN", command=lambda: self.board_action("pin"))
        pin_button.pack(side="left")
        self.controls.append(pin_button)
        ttk.Button(control_bar, text="Lock / Reset entry", command=lambda: self.board_action("lock")).pack(side="left", padx=6)
        restore_button = ttk.Button(control_bar, text="Restore defaults", command=self.restore)
        restore_button.pack(side="left")
        self.controls.append(restore_button)
        duration_bar = ttk.Frame(container)
        duration_bar.grid(row=6, column=0, columnspan=3, sticky="w", pady=5)
        ttk.Label(duration_bar, text="Unlock ms:").pack(side="left")
        ttk.Entry(duration_bar, textvariable=self.unlock_ms, width=6).pack(side="left", padx=6)
        duration_button = ttk.Button(duration_bar, text="Save duration", command=lambda: self.board_action("duration"))
        duration_button.pack(side="left")
        self.controls.append(duration_button)
        self.status = tk.StringVar(value="Recognize a digit, inspect the result, then Confirm digit / KEY4.")
        ttk.Label(container, textvariable=self.status, wraplength=600).grid(row=7, column=0, columnspan=3, sticky="w", pady=8)
        self.peripherals = tk.StringVar(value="KEY2 lock | KEY3 undo | KEY4 confirm | KEY5 mode | KEY6 recognize | KEY7 clear | KEY8 hold 2s defaults")
        ttk.Label(container, textvariable=self.peripherals, wraplength=600).grid(row=8, column=0, columnspan=3, sticky="w")
        self.result = tk.Text(container, width=70, height=9, font=("Consolas", 10), state="disabled")
        self.result.grid(row=9, column=0, columnspan=3, pady=(8, 0))
        root.protocol("WM_DELETE_WINDOW", self.close)
        root.after(250, self.refresh_status)

    def update_controls(self):
        busy = self.pending is not None and self.pending_kind != "status"
        for control in self.controls:
            control.state(["disabled" if busy else "!disabled"])
        self.mode_box.configure(state="disabled" if busy else "readonly")
        self.confirm_button.state(["!disabled" if self.active_token and not busy and not self.offline else "disabled"])

    def submit(self, operation, kind="action", priority=False):
        if self.closing:
            return
        if kind == "status" and (self.pending is not None or self.queue):
            return
        if priority:
            self.queue.clear()
            self.queue.appendleft((kind, operation))
            self.active_token = 0
            self.status.set("Lock requested; waiting for board acknowledgement...")
        else:
            self.queue.append((kind, operation))
        self.start_next()

    def start_next(self):
        if self.pending is not None or not self.queue or self.closing:
            self.update_controls()
            return
        self.pending_kind, operation = self.queue.popleft()
        if self.pending_kind != "status":
            self.status.set("Locking..." if self.pending_kind == "lock" else "Processing...")
        self.pending = self.executor.submit(operation)
        self.update_controls()
        self.root.after(25, self.poll)

    def show_json(self, result):
        self.result.configure(state="normal")
        self.result.delete("1.0", "end")
        self.result.insert("end", json.dumps(result, indent=2))
        self.result.configure(state="disabled")

    def apply_status(self, result):
        if "remaining_ms" in result:
            state = f"UNLOCKED {result['remaining_ms'] / 1000:.1f}s" if result["unlocked"] else "ALARM" if result["alarm"] else "LOCKED"
            candidate = f" | Confirm {result['digit']}" if result["candidate_valid"] else ""
            self.status.set(f"{state} | PIN entry: {result['pin_count']}/4{candidate}")
            self.mode.set(result["mode"])
            storage = "SAVE ERROR" if result["configuration_error"] else "SAVED" if result["configuration_saved"] else "DEFAULT / UNSAVED"
            self.peripherals.set(f"HDMI: {'configured' if result['hdmi_initialized'] else 'not configured'} | EEPROM: {storage} | UART overflow/frame errors: {result['uart_overrun']}/{result['uart_framing']}")
        if "candidate_valid" in result:
            self.active_token = result.get("token", 0) if result["candidate_valid"] and self.recognized_revision == self.revision else 0

    def poll(self):
        if not self.pending.done():
            self.root.after(25, self.poll)
            return
        kind = self.pending_kind
        try:
            result = self.pending.result()
            if kind != "status":
                self.show_json(result)
            if kind == "connect":
                self.poll_enabled = True
            if kind == "recognize":
                if self.offline:
                    self.status.set(f"Local preview digit: {result['digit']} | PC inference")
                else:
                    self.status.set(f"Digit: {result['digit']} | inspect the preview, then Confirm digit")
            self.apply_status(result)
        except BoardError as error:
            self.show_json(error.result)
            self.active_token = 0
            self.status.set(str(error))
        except Exception as error:
            self.active_token = 0
            self.poll_enabled = False
            self.status.set(f"{error} | Board state unknown; reconnect to refresh.")
        finally:
            self.pending = None
            self.pending_kind = None
            self.start_next()

    def refresh_status(self):
        if self.closing:
            return
        if self.board is not None and self.poll_enabled:
            self.submit(self.board.status, "status")
        self.root.after(250, self.refresh_status)

    def connect(self):
        port = self.port.get().strip()
        if not port:
            self.status.set("Select a COM port first")
            return
        def operation():
            if self.board:
                self.board.close()
                self.board = None
            board = Board(port)
            try:
                identity = board.hello()
                state = board.status()
            except Exception:
                board.close()
                raise
            self.board = board
            return {**identity, **state}
        self.submit(operation, "connect")

    def clear(self, notify=True):
        self.canvas.delete("all")
        self.image = Image.new("L", (280, 280))
        self.draw = ImageDraw.Draw(self.image)
        self.sample_pixels = None
        self.previous = None
        self.revision += 1
        self.active_token = 0
        self.update_controls()
        if notify and self.board is not None:
            self.submit(self.board.clear, "clear")

    def start_stroke(self, event):
        if self.pending is not None and self.pending_kind != "status":
            return
        if self.sample_pixels is not None:
            self.clear(False)
        self.revision += 1
        self.active_token = 0
        self.update_controls()
        self.previous = (event.x, event.y)
        self.canvas.create_oval(event.x - 9, event.y - 9, event.x + 9, event.y + 9, fill="white", outline="white")
        self.draw.ellipse((event.x - 9, event.y - 9, event.x + 9, event.y + 9), fill=255)

    def draw_stroke(self, event):
        if self.pending is not None and self.pending_kind != "status":
            return
        point = (event.x, event.y)
        if self.previous:
            self.canvas.create_line(*self.previous, *point, fill="white", width=18, capstyle="round", smooth=True)
            self.draw.line((self.previous, point), fill=255, width=18)
            self.draw.ellipse((event.x - 9, event.y - 9, event.x + 9, event.y + 9), fill=255)
        self.previous = point

    def load_sample(self):
        self.clear(False)
        self.sample_pixels = self.samples[int(self.sample.get())]
        image = Image.frombytes("L", (16, 16), bytes(value * 2 for value in self.sample_pixels))
        self.sample_photo = ImageTk.PhotoImage(image.resize((280, 280), Image.Resampling.NEAREST))
        self.canvas.create_image(0, 0, image=self.sample_photo, anchor="nw")

    def recognize(self):
        try:
            pixels = self.sample_pixels if self.sample_pixels is not None else prepare_image(self.image)
            if not self.offline and self.board is None:
                raise ValueError("Connect the board first")
            small = Image.frombytes("L", (16, 16), bytes(int(value) * 2 for value in pixels))
            self.preview_photo = ImageTk.PhotoImage(small.resize((128, 128), Image.Resampling.NEAREST))
            self.preview.configure(image=self.preview_photo)
            mode = self.mode.get()
            self.recognized_revision = self.revision
            def operation():
                if self.offline:
                    return self.local_model.infer(pixels)
                try:
                    return self.board.infer(pixels, mode, detailed=mode == "compare")
                except BoardError as error:
                    if error.status == 4:
                        error.result.update(self.board.diagnostics())
                    raise
            self.submit(operation, "recognize")
        except Exception as error:
            self.status.set(str(error))

    def board_action(self, action):
        if self.offline or (self.board is None and self.pending_kind != "connect"):
            self.status.set("This control requires a connected board")
            return
        pin = self.pin.get()
        mode = self.mode.get()
        duration = self.unlock_ms.get()
        token = self.active_token
        if action == "confirm" and not token:
            self.status.set("Recognize the current drawing before confirming")
            return
        def operation():
            if self.board is None:
                raise ValueError("Connect the board first")
            if action == "pin":
                return self.board.set_pin(pin)
            if action == "mode":
                return self.board.set_mode(mode)
            if action == "confirm":
                return self.board.confirm(token)
            if action == "cancel":
                return self.board.cancel()
            if action == "duration":
                return self.board.set_unlock_ms(int(duration))
            if action == "restore":
                return self.board.restore_defaults()
            return self.board.lock()
        self.submit(operation, action, priority=action == "lock")

    def restore(self):
        if not self.offline and self.board is not None and messagebox.askyesno("Restore defaults", "Restore PIN 1234, hardware mode and a 5 second unlock duration in EEPROM?"):
            self.board_action("restore")

    def close(self):
        self.closing = True
        self.queue.clear()
        if self.pending is not None:
            self.status.set("Waiting for the current board operation to finish...")
            self.root.after(100, self.close)
            return
        if self.board:
            self.board.close()
        self.executor.shutdown(wait=False)
        self.root.destroy()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port")
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    root = tk.Tk()
    Demo(root, args.port, args.offline)
    root.mainloop()


if __name__ == "__main__":
    main()
