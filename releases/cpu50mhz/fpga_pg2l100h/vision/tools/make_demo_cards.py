import argparse
from pathlib import Path

import pymupdf


ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description="Create printable numeric labels and a negative-test sheet")
    parser.add_argument("--output", type=Path, default=ROOT / "competition/demo_cards.pdf")
    args = parser.parse_args()
    document = pymupdf.open()
    for title, symbols in [("NUMGUARD: numeric labels 0-9", list("0123456789")), ("NUMGUARD: negative and empty-scene tests", ["A", "F", "K", "M", "X", "+", "=", "*", "", ""])]:
        page = document.new_page(width=595, height=842)
        page.insert_text((30, 25), title, fontsize=14)
        page.insert_text((30, 43), "Print at 100 percent. Present one card. Keep captions outside camera ROI.", fontsize=10)
        for index, symbol in enumerate(symbols):
            left = 28 + index % 2 * 275
            top = 62 + index // 2 * 151
            rectangle = pymupdf.Rect(left, top, left + 263, top + 139)
            page.draw_rect(rectangle, color=(0.7, 0.7, 0.7), dashes="[3 3] 0")
            page.insert_text((left + 105, top + 97), symbol, fontsize=100, fontname="hebo")
            page.insert_text((left + 10, top + 128), f"CARD {index + 1:02d}  {symbol if symbol else 'EMPTY'}", fontsize=9)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    document.save(args.output)
    document.close()
    print(args.output)


if __name__ == "__main__":
    main()
