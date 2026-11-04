# -*- coding: utf-8 -*-
"""竞赛技术报告配图 1/2 —— 可复现绘制源码。

背景
----
原两张图（设计流程图、硬件架构框图）由外部绘图工具制作后插入报告，
仓库内原本**没有**任何绘制脚本或矢量源文件。此文件把两张图补成
"代码即设计稿"：所有样式集中在 STYLE，所有文字与连线关系集中在
fig1()/fig2() 的数据区，改样式不动内容，改内容不动样式。

复现
----
    python docs/figures/draw_report_figures.py             # 输出两张 PNG 到本目录
    python docs/figures/draw_report_figures.py --scale 3  # 更高分辨率
    python docs/figures/draw_report_figures.py --only fig1

视觉优化清单（相对原图，仅改表现形式，不改任何文字与拓扑）
------------------------------------------------------------
1. 配色：四色分区由高饱和荧光色改为低饱和、明度分层的同色系，
   分区底色更浅、描边更细；标题统一用深色版，保证与底色对比度；
   节点正文统一深墨色，不再随分区变色，长文更易读。
2. 字体与字号：统一微软雅黑（常规/粗体两级），建立 5 级字号层级
   （核心板标题 > 分区标题 > 节点主文 > 辅助小字 > 分支标签），
   原图小字放大到可印刷的可读尺寸。
3. 坐标轴与网格：本类图为流程/框图，原本没有坐标轴；对应处理是
   去掉扫描噪点与抖动边框，改用统一的细分隔线、对齐基线和克制的
   投影，形成隐性的对齐网格，不引入任何新信息。
4. 图例布局：右侧图例改为"线样 + 名称 + 两行说明"的固定栅格，
   四条等距、左对齐、行距统一，线样与文字不再互相挤压。
5. 留白与边距：统一外边距、分区内边距、节点间距；分区之间留出
   连接线走廊，跨区连线不再压住标题与节点文字。
6. 数据标签：节点内主文/辅助小字/彩色强调行分三层排版；
   判断分支标签加浅色底衬；连线按"流"着色并统一箭头尺寸。
7. 疏排（v2）：图 1 画布 1200×604 → 1480×800，节点放大 1.2×、字号 1.12×、
   间距放大更多；跨区连线按 y=152 / 410 / 428 / 495 / 600 / 746 分配独立
   通道，绿/橙两路不再汇合共线，「未通过」回环改走右侧外通道，紫色回卷
   改走左侧外通道，全程不与任何节点、文字或其他连线重叠。图 2 采用
   几何 ×1.18、字号 ×1.12 的等比疏排，连线拓扑保持不变。
"""

from __future__ import annotations

import argparse
import math
import os
from typing import Iterable, Sequence

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------------------
# 设计参数：改动视觉效果只需改这里
# ---------------------------------------------------------------------------
STYLE = {
    # 中性色
    "paper": "#FFFFFF",
    "ink": "#1B2430",          # 节点/图例主文
    "ink_soft": "#5C6879",     # 辅助小字
    "hairline": "#D8E0EA",     # 分隔线/对齐基线
    "shadow": "#E9EEF5",       # 克制的投影
    # 四色分区：main=节点色条/连线，deep=标题，tint=分区底，edge=分区描边
    "blue":   {"main": "#2563EB", "deep": "#1D4ED8", "tint": "#F4F8FF", "edge": "#C9DAFB"},
    "green":  {"main": "#0E9F6E", "deep": "#047857", "tint": "#F2FBF7", "edge": "#C5E9D8"},
    "amber":  {"main": "#E08A0C", "deep": "#B45309", "tint": "#FFF9F0", "edge": "#F2DCB8"},
    "violet": {"main": "#7C56E0", "deep": "#6D28D9", "tint": "#F9F6FE", "edge": "#DED1F8"},
    "red":    {"main": "#DC4C4C", "deep": "#B91C1C", "tint": "#FEF4F4", "edge": "#F3CFCF"},
    # 字号层级（逻辑像素，输出时整体乘 scale）
    "fit_min": 0.74,          # 长标签自动缩字号的下限，避免溢出节点
    "fs": {
        "board": 27,          # 核心板标题
        "section": 23,        # 分区标题
        "node": 18,           # 节点主文
        "node_sub": 13,       # 节点内辅助小字
        "node_tag": 13,       # 节点内彩色强调行
        "branch": 13,         # 判断分支标签
        "legend_title": 20,
        "legend_item": 16,
        "legend_note": 12.5,
        "chip": 12.5,         # 底部接口小块
    },
    # 几何
    "r_panel": 16,
    "r_node": 11,
    "r_chip": 9,
    "strip": 7,              # 节点左侧色条宽度（原图约 11px，收细）
    "stroke_panel": 1.4,
    "stroke_node": 1.3,
    "stroke_link": 2.2,
    "arrow_len": 11,
    "arrow_half": 5.2,
    "dash": (9, 7),
    "shadow_dy": 3,
    "text_gap": 5,           # 主文/小字之间的垂直间距
    "font_regular": r"C:\Windows\Fonts\msyh.ttc",
    "font_bold": r"C:\Windows\Fonts\msyhbd.ttc",
}

# ---------------------------------------------------------------------------
# 内容数据：文字与拓扑的唯一来源。优化视觉时不要改动这一段的语义。
# 频率口径：以 fpga_pg2l100h/vision/CURRENT-BUILD.md（当前烧录版）为准 ——
#   CPU / IMEM / DMEM = 95 MHz（双发射），MMIO / NPU / 采集 = 50 MHz。
#   125 MHz 是上一版单发射的历史配置，仓库里 CLOCK_SPLIT.md 等旧文档仍写 125，勿据此回填。
# ---------------------------------------------------------------------------
FIG1_FLOW = {
    "blue": ["RV32IM指令集\n与功能划分", "五级流水线\n结构设计", "分支预测 · 旁路\n冒险处理",
             "CPU模块化\nRTL实现", "指令与流水线\n仿真验证"],
    "green": ["IMEM / DMEM\nMMIO\n地址空间", "请求应答桥\n95 ↔ 50\nMHz",
              "摄像头 ·\nLCD\nUART外设", "INT8卷积\n加速器"],
    "amber": ["视觉模型\n训练", "INT8\n量化转换", "权重 · 偏置\n移位参数", "阈值 · 解码\nNMS固件"],
    "violet_top": ["CPU调度NPU\n结果读取", "严格Verilog\n编译", "模块仿真", "整机仿真",
                   "PDS综合\n时序分析"],
    "violet_bottom": ["布局布线\n位流生成", "位流下载\n板级运行", "LCD预览与\n功能目视检查"],
}

FIG2_BOARD = {
    "cam": ("OV7670摄像头 · J7", "RGB565 图像输入与 SCCB 配置"),
    "lcd": ("AN430液晶显示 · J11", "实时预览 · 状态文字 · 检测框"),
    "power": [
        ("12 V直流输入", "J1 · 防反接 · 保险丝 · 开关", ""),
        ("三级DC-DC降压", "SC1221 × 3", "5 V · 3.3 V · 1.2 V"),
        ("电源分配", "核心板 · 摄像头 · LCD ·\n外设", ""),
    ],
    "modules": [
        ("RV32IM处理器", "五级流水 · CSR · 中断", "95 MHz CPU域", "blue"),
        ("片上存储系统", "IMEM 32 KiB · DMEM 16 KiB\n帧缓冲 · 模型 ROM", "", "slate"),
        ("MMIO与CDC桥", "请求/应答握手", "95 ↔ 50 MHz", "violet"),
        ("视频采集与显示", "DVP 采集 · 双缓冲\nLCD 时序与检测叠加", "", "green"),
        ("INT8卷积加速器", "64 × 64 模型输入", "50 MHz NPU域", "amber"),
        ("外设控制逻辑", "UART · 按键 · LED\n定时器 · PWM · JTAG", "", "slate"),
    ],
    "legend": [
        ("电源流", "12 V 输入，经保护与三级降压，\n供核心板 / 摄像头 / LCD", "amber"),
        ("图像数据流", "摄像头、双缓冲、NPU 与 LCD\n之间的图像数据", "blue"),
        ("显示输出流", "24 bit RGB 数据与 LCD 显示时序", "green"),
        ("控制与调试流", "CPU 调度、MMIO、SCCB、UART、\n数码管、JTAG 与 PWM", "violet"),
    ],
    "debug": [
        ("USB转串口 · J9", "UART · TXD/RXD"),
        ("按键与LED", "GPIO · KEY · LED"),
        ("JTAG · J6", "TCK/TMS/TDI/TDO"),
        ("风扇与PWM", "FAN_PWM"),
        ("预留扩展", "IO 扩展 · LED · B"),
    ],
}


# 微软雅黑字库不含 U+2194（↔），渲染成豆腐块；用等义的双向箭头组合替代。
# 只影响字形，不改变数据区里的文字与含义。
GLYPH_FALLBACK = {"↔": "←→"}


def fix_glyphs(s: str) -> str:
    for src, dst in GLYPH_FALLBACK.items():
        s = s.replace(src, dst)
    return s


class Canvas:
    """逻辑坐标画布；所有绘制统一按 scale 放大，保证高分输出。"""

    def __init__(self, width: int, height: int, scale: int = 2,
                 font_scale: float = 1.0, layout_scale: float = 1.0):
        self.w, self.h, self.s = width, height, scale
        # 几何放大系数 > 字号放大系数 ⇒ 净增留白；两者比例不变 ⇒ 风格不变
        self.layout_scale, self.font_scale = layout_scale, font_scale
        self.im = Image.new("RGB", (self.P(width), self.P(height)), STYLE["paper"])
        self.d = ImageDraw.Draw(self.im)
        self._fonts: dict = {}

    def P(self, v: float) -> int:
        return int(round(v * self.s * self.layout_scale))

    def box(self, b: Sequence[float]):
        return tuple(self.P(v) for v in b)

    def font(self, size: float, bold: bool = False):
        px = max(1, int(round(size * self.s * self.font_scale)))
        key = (px, bold)
        if key not in self._fonts:
            path = STYLE["font_bold"] if bold else STYLE["font_regular"]
            self._fonts[key] = ImageFont.truetype(path, px)
        return self._fonts[key]

    def color(self, tone: str, role: str = "main") -> str:
        if tone == "slate":
            return {"main": "#7A8798", "deep": "#3F4B5B", "tint": "#FAFBFD",
                    "edge": "#DDE4EC"}[role]
        return STYLE[tone][role]

    # --- 基础图元 -----------------------------------------------------------
    def rr(self, b, radius, fill, outline=None, width=1.3, shadow=False):
        if shadow:
            dy = self.P(STYLE["shadow_dy"])
            self.d.rounded_rectangle(
                (self.P(b[0]), self.P(b[1]) + dy, self.P(b[2]), self.P(b[3]) + dy),
                radius=self.P(radius), fill=STYLE["shadow"])
        kw = {}
        if outline:
            kw = {"outline": outline, "width": max(1, self.P(width))}
        self.d.rounded_rectangle(self.box(b), radius=self.P(radius), fill=fill, **kw)

    def poly(self, pts, fill, outline, width=1.4):
        self.d.polygon([(self.P(x), self.P(y)) for x, y in pts], fill=fill)
        self.d.line([(self.P(x), self.P(y)) for x, y in pts + [pts[0]]],
                    fill=outline, width=max(1, self.P(width)), joint="curve")

    def _arrow_head(self, a, b, color, width):
        dx, dy = b[0] - a[0], b[1] - a[1]
        length = math.hypot(dx, dy)
        if length < 1:
            return
        ux, uy = dx / length, dy / length
        nx, ny = -uy, ux
        # 短间距（如相邻节点之间）自动收小箭头，避免箭头压住节点边框
        L = min(self.P(STYLE["arrow_len"]), length * 0.85)
        H = self.P(STYLE["arrow_half"]) * min(1.0, L / self.P(STYLE["arrow_len"]))
        if L < 3:
            return
        base = (b[0] - ux * L, b[1] - uy * L)
        self.d.line([base, b], fill=color, width=width)
        self.d.polygon([b, (base[0] + nx * H, base[1] + ny * H),
                        (base[0] - nx * H, base[1] - ny * H)], fill=color)

    def _dashed(self, pts, fill, width):
        on, off = (self.P(v) for v in STYLE["dash"])
        for a, b in zip(pts, pts[1:]):
            dx, dy = b[0] - a[0], b[1] - a[1]
            L = math.hypot(dx, dy)
            if L < 1:
                continue
            ux, uy = dx / L, dy / L
            t = 0.0
            while t < L:
                e = min(t + on, L)
                self.d.line([(a[0] + ux * t, a[1] + uy * t),
                             (a[0] + ux * e, a[1] + uy * e)], fill=fill, width=width)
                t = e + off

    def link(self, points: Iterable[Sequence[float]], tone: str,
             width: float | None = None, arrow: bool = True, dash: bool = False):
        color = self.color(tone)
        pts = [(self.P(x), self.P(y)) for x, y in points]
        w = max(1, self.P(width or STYLE["stroke_link"]))
        if dash:
            self._dashed(pts, color, w)
        else:
            self.d.line(pts, fill=color, width=w, joint="curve")
        if arrow and len(pts) >= 2:
            self._arrow_head(pts[-2], pts[-1], color, w)

    def text(self, x, y, s, size, color=None, bold=False, anchor="mm", align="center"):
        """单行/多行文字；anchor 用 Pillow 的两字符锚点。"""
        f = self.font(size, bold)
        sp = self.P(4)
        self.d.multiline_text((self.P(x), self.P(y)), fix_glyphs(s), font=f,
                              fill=color or STYLE["ink"], spacing=sp,
                              anchor=anchor, align=align)

    def fit(self, parts, avail):
        """长标签自动降字号，保证任何文字都不越出节点边界。"""
        limit = self.P(avail)
        widest = 1
        for text, size, bold, color, gap in parts:
            bb = self.d.multiline_textbbox(
                (0, 0), fix_glyphs(text), font=self.font(size, bold), spacing=self.P(4))
            widest = max(widest, bb[2] - bb[0])
        if widest <= limit:
            return parts
        k = max(STYLE["fit_min"], limit / widest)
        return [(t, s * k, b, c, g) for (t, s, b, c, g) in parts]

    def block(self, cx, cy, parts):
        """垂直堆叠的文字块，整块以 cy 垂直居中。

        parts: [(text, size, bold, color, gap_after), ...]
        """
        metas = []
        total = 0
        for text, size, bold, color, gap in parts:
            text = fix_glyphs(text)
            f = self.font(size, bold)
            sp = self.P(4)
            bb = self.d.multiline_textbbox((0, 0), text, font=f, spacing=sp,
                                           anchor="ma", align="center")
            metas.append((bb[1], bb[3] - bb[1], f, sp))
            total += (bb[3] - bb[1]) + self.P(gap)
        y = self.P(cy) - total / 2
        for (text, size, bold, color, gap), (y0, h, f, sp) in zip(parts, metas):
            self.d.multiline_text((self.P(cx), y - y0), fix_glyphs(text), font=f, fill=color,
                                  spacing=sp, anchor="ma", align="center")
            y += h + self.P(gap)

    # --- 语义图元 -----------------------------------------------------------
    def panel(self, b, title, tone, title_y=None, divider=True, board_head=False):
        self.rr(b, STYLE["r_panel"], self.color(tone, "tint"),
                self.color(tone, "edge"), STYLE["stroke_panel"])
        cx = (b[0] + b[2]) / 2
        ty = title_y if title_y is not None else b[1] + 24
        if board_head:
            head = (b[0] + 2, b[1] + 2, b[2] - 2, b[1] + 46)
            self.rr(head, 12, self.color(tone, "edge"))
            self.text(cx, b[1] + 25, title, STYLE["fs"]["board"],
                      self.color(tone, "deep"), bold=True)
        else:
            self.text(cx, ty, title, STYLE["fs"]["section"],
                      self.color(tone, "deep"), bold=True)
        if divider and not board_head:
            y = (title_y if title_y is not None else b[1] + 24) + 21
            self.d.line([(self.P(b[0] + 18), self.P(y)),
                         (self.P(b[2] - 18), self.P(y))],
                        fill=self.color(tone, "edge"), width=max(1, self.P(0.9)))

    def node(self, b, title, tone, sub=None, tag=None, sub_size=None):
        self.rr(b, STYLE["r_node"], STYLE["paper"], self.color(tone, "edge"),
                STYLE["stroke_node"], shadow=True)
        strip = STYLE["strip"]
        self.rr((b[0] + 1.5, b[1] + 3, b[0] + 1.5 + strip, b[3] - 3),
                3, self.color(tone), None)
        cx = (b[0] + b[2]) / 2 + strip / 2 + 1.5
        cy = (b[1] + b[3]) / 2
        fs = STYLE["fs"]
        parts = [(title, fs["node"], True, STYLE["ink"], STYLE["text_gap"])]
        if sub:
            parts.append((sub, sub_size or fs["node_sub"], False,
                          STYLE["ink_soft"], STYLE["text_gap"]))
        if tag:
            parts.append((tag, fs["node_tag"], True, self.color(tone, "deep"), 0))
        # 左右各留 9px 内边距，文字永远不贴色条、不越边框
        avail = (b[2] - b[0]) - 18 - strip
        self.block(cx, cy, self.fit(parts, avail))

    def plain_node(self, b, title, tone="slate", sub=None, size=None):
        self.rr(b, STYLE["r_node"], STYLE["paper"], self.color(tone, "edge"),
                STYLE["stroke_node"], shadow=True)
        cx, cy = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
        fs = STYLE["fs"]
        parts = [(title, size or fs["node"], True, STYLE["ink"], STYLE["text_gap"])]
        if sub:
            parts.append((sub, fs["node_sub"], False, STYLE["ink_soft"], 0))
        self.block(cx, cy, self.fit(parts, (b[2] - b[0]) - 20))

    def diamond(self, cx, cy, w, h, label):
        pts = [(cx, cy - h / 2), (cx + w / 2, cy), (cx, cy + h / 2), (cx - w / 2, cy)]
        self.poly(pts, "#FFFCF3", STYLE["amber"]["main"], 1.6)
        self.text(cx, cy, label, STYLE["fs"]["node"], STYLE["ink"], bold=True)

    def pill(self, b, text, tone="red", dashed=False):
        self.rr(b, (b[3] - b[1]) / 2, self.color(tone, "tint"),
                self.color(tone, "edge"), 1.2)
        self.text((b[0] + b[2]) / 2, (b[1] + b[3]) / 2, text,
                  STYLE["fs"]["chip"], self.color(tone, "deep"), bold=True)

    def branch_label(self, x, y, text, tone):
        b = (x - 30, y - 13, x + 30, y + 13)
        self.rr(b, 10, self.color(tone, "tint"), None)
        self.text(x, y, text, STYLE["fs"]["branch"],
                  self.color(tone, "deep"), bold=True)

    def legend_item(self, x, y, w, name, note, tone):
        color = self.color(tone)
        self.link([(x, y), (x + 46, y)], tone, width=2.6)
        self.text(x + 62, y, name, STYLE["fs"]["legend_item"], STYLE["ink"], bold=True,
                  anchor="lm", align="left")
        f = self.font(STYLE["fs"]["legend_note"])
        sp = self.P(3)
        self.d.multiline_text((self.P(x), self.P(y + 15)), note, font=f,
                              fill=STYLE["ink_soft"], spacing=sp, anchor="la", align="left")


# ---------------------------------------------------------------------------
# 图 1：处理器设计与系统联调流程
# ---------------------------------------------------------------------------
def fig1(scale: int = 2) -> Image.Image:
    """疏排版：画布与间距放大，跨区连线各自占用独立通道，互不共线/交叉/穿节点。

    通道分配（逻辑 y 坐标，全部落在分区之间的空白走廊内）：
      y=152  蓝区 → SoC / 模型部署（左右两段，x 区间不重叠）
      y=410  SoC → 系统联调        绿，落点 x=100
      y=428  模型部署 → 系统联调  橙，落点 x=250（与绿线平行分离）
      y=495  红色「未通过」回环    走第一行上方 + 右侧外通道
      y=600  紫色回卷              走两行之间 + 左侧外通道
      y=746  回环下行              走第二行下方
    """
    W, H = 1480, 800
    c = Canvas(W, H, scale, font_scale=1.12)
    fs = STYLE["fs"]

    TOP = (22, 16, 1458, 140)
    GREEN = (22, 170, 720, 400)
    AMBER = (760, 170, 1458, 400)
    BOT = (22, 436, 1458, 784)

    # 分区（先画底，连接线随后，节点最后覆盖线端）
    c.panel(TOP, "处理器设计", "blue", title_y=44)
    c.panel(GREEN, "SoC与外设集成", "green", title_y=202)
    c.panel(AMBER, "模型与固件部署", "amber", title_y=202)
    # 底部让出 y≈495 的回环通道，故不画标题分隔线
    c.panel(BOT, "系统联调与逐级验证", "violet", title_y=464, divider=False)

    # 节点几何：节点放大 1.2 倍，间距放大更多 ⇒ 净增留白
    top_w, top_gap, top_y, top_h = 240, 42, 76, 56
    top_boxes = [(56 + i * (top_w + top_gap), top_y,
                  56 + i * (top_w + top_gap) + top_w, top_y + top_h)
                 for i in range(5)]

    side_w, side_gap, side_y, side_h = 150, 26, 236, 94
    green_boxes = [(32 + i * (side_w + side_gap), side_y,
                    32 + i * (side_w + side_gap) + side_w, side_y + side_h)
                   for i in range(4)]
    amber_boxes = [(770 + i * (side_w + side_gap), side_y,
                    770 + i * (side_w + side_gap) + side_w, side_y + side_h)
                   for i in range(4)]

    vt_y, vt_h = 518, 62
    vt_boxes = [(56 + i * (top_w + top_gap), vt_y,
                 56 + i * (top_w + top_gap) + top_w, vt_y + vt_h) for i in range(5)]
    vb_y, vb_h = 636, 62
    vb_boxes = [(56 + i * (top_w + top_gap), vb_y,
                 56 + i * (top_w + top_gap) + top_w, vb_y + vb_h) for i in range(3)]
    dia_cx, dia_cy, dia_w, dia_h = 1010, 667, 170, 92
    done_box = (1180, 632, 1424, 704)
    loop_pill = (780, 728, 1160, 764)

    # --- 跨区连接：每条独立通道，不共线、不交叉 ---
    c.link([(176, 132), (176, 152), (107, 152), (107, 236)], "green")
    c.link([(1424, 104), (1444, 104), (1444, 152), (845, 152), (845, 236)], "amber")
    c.link([(635, 330), (635, 410), (100, 410), (100, 518)], "green")
    c.link([(1373, 330), (1373, 428), (250, 428), (250, 518)], "amber")
    c.link([(1304, 580), (1304, 600), (40, 600), (40, 667), (56, 667)], "violet")

    # --- 区内水平箭头 ---
    for boxes, tone, y in ((top_boxes, "blue", 104), (green_boxes, "green", 283),
                           (amber_boxes, "amber", 283), (vt_boxes, "violet", 549)):
        for a, b in zip(boxes, boxes[1:]):
            c.link([(a[2] + 5, y), (b[0] - 6, y)], tone, width=1.9)
    for a, b in zip(vb_boxes, vb_boxes[1:]):
        c.link([(a[2] + 5, 667), (b[0] - 6, 667)], "violet", width=1.9)
    c.link([(vb_boxes[2][2] + 5, 667), (dia_cx - dia_w / 2 - 6, 667)], "violet")

    # 判断分支与回路
    c.link([(dia_cx + dia_w / 2 + 5, 667), (done_box[0] - 6, 667)], "green")
    c.link([(dia_cx, dia_cy + dia_h / 2 + 2), (dia_cx, 728)], "red",
           arrow=False, dash=True)
    c.link([(loop_pill[2] + 4, 746), (1430, 746), (1430, 495),
            (458, 495), (458, 518)], "red", dash=True)

    # --- 节点 ---
    for b, t in zip(top_boxes, FIG1_FLOW["blue"]):
        c.node(b, t, "blue")
    for b, t in zip(green_boxes, FIG1_FLOW["green"]):
        c.node(b, t, "green")
    for b, t in zip(amber_boxes, FIG1_FLOW["amber"]):
        c.node(b, t, "amber")
    for b, t in zip(vt_boxes, FIG1_FLOW["violet_top"]):
        c.node(b, t, "violet")
    for b, t in zip(vb_boxes, FIG1_FLOW["violet_bottom"]):
        c.node(b, t, "violet")

    c.diamond(dia_cx, dia_cy, dia_w, dia_h, "满足要求？")
    c.rr(done_box, STYLE["r_node"], STYLE["green"]["tint"],
         STYLE["green"]["main"], 1.5, shadow=True)
    c.rr((done_box[0] + 1.5, done_box[1] + 3, done_box[0] + 9, done_box[3] - 3),
         3, STYLE["green"]["main"], None)
    c.text((done_box[0] + done_box[2]) / 2 + 4, (done_box[1] + done_box[3]) / 2,
           "设计完成", fs["node"] + 1, STYLE["green"]["deep"], bold=True)
    c.pill(loop_pill, "问题定位：修改RTL / 约束 / 器件")

    c.branch_label(1137, 645, "通过", "green")
    c.branch_label(1130, 714, "未通过", "red")
    return c.im


# ---------------------------------------------------------------------------
# 图 2：PG2L100H 硬件架构与信号流
# ---------------------------------------------------------------------------
def fig2(scale: int = 2) -> Image.Image:
    W, H = 1200, 548
    # 等比疏排：几何 ×1.18、字号 ×1.12 ⇒ 净增留白；连线拓扑与上一版一致
    c = Canvas(W, H, scale, font_scale=1.12, layout_scale=1.18)
    fs = STYLE["fs"]

    POWER = (12, 10, 206, 432)
    CORE = (216, 68, 902, 432)
    LEGEND = (912, 10, 1188, 432)
    DEBUG = (216, 444, 902, 538)
    CAM = (250, 6, 510, 60)
    LCD = (620, 6, 880, 60)

    c.panel(POWER, "板级供电与保护", "amber", title_y=32)
    c.panel(CORE, "PG2L100H FPGA核心板", "blue", board_head=True)
    c.panel(LEGEND, "接口与信号说明", "violet", title_y=32, divider=False)
    c.panel(DEBUG, "调试交互与扩展接口", "violet", title_y=462, divider=False)

    # 顶部两个外部模块
    for b, (title, sub) in ((CAM, FIG2_BOARD["cam"]), (LCD, FIG2_BOARD["lcd"])):
        tone = "blue" if b is CAM else "green"
        c.rr(b, STYLE["r_node"], c.color(tone, "tint"), c.color(tone, "edge"),
             STYLE["stroke_node"], shadow=True)
        c.block((b[0] + b[2]) / 2, (b[1] + b[3]) / 2,
                c.fit([(title, fs["node"] - 1, True, STYLE["ink"], 3),
                       (sub, fs["node_sub"] - 0.5, False, STYLE["ink_soft"], 0)],
                      (b[2] - b[0]) - 24))

    # 供电链三节点（原图为橙/棕，统一为琥珀色系）
    pw_boxes = [(28, 62, 190, 148), (28, 170, 190, 276), (28, 298, 190, 396)]
    for b, (title, sub, tag) in zip(pw_boxes, FIG2_BOARD["power"]):
        c.rr(b, STYLE["r_node"], STYLE["paper"], c.color("amber", "edge"),
             STYLE["stroke_node"], shadow=True)
        pw_parts = ([(title, fs["node"], True, STYLE["ink"], 7),
                     (sub, fs["node_sub"], False, STYLE["ink_soft"], 5 if tag else 0)]
                    + ([(tag, fs["node_tag"], True, STYLE["amber"]["deep"], 0)] if tag else []))
        c.block((b[0] + b[2]) / 2, (b[1] + b[3]) / 2,
                c.fit(pw_parts, (b[2] - b[0]) - 22))
    c.link([(109, 148), (109, 170)], "amber", width=1.8)
    c.link([(109, 276), (109, 298)], "amber", width=1.8)

    # 核心板内六个模块
    cols = [(236, 430), (448, 662), (680, 882)]
    rows = [(132, 242), (258, 368)]
    mod_boxes = []
    for r, (y0, y1) in enumerate(rows):
        for k, (x0, x1) in enumerate(cols):
            mod_boxes.append((x0, y0, x1, y1))
    for b, (title, sub, tag, tone) in zip(mod_boxes, FIG2_BOARD["modules"]):
        c.rr(b, STYLE["r_node"], STYLE["paper"], c.color(tone, "edge"),
             STYLE["stroke_node"], shadow=True)
        cx, cy = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
        parts = [(title, fs["node"], True, STYLE["ink"], 8),
                 (sub, fs["node_sub"] - 0.5, False, STYLE["ink_soft"],
                  7 if tag else 0)]
        if tag:
            parts.append((tag, fs["node_tag"], True, c.color(tone, "deep"), 0))
        c.block(cx, cy, c.fit(parts, (b[2] - b[0]) - 26))

    # 底部五个接口小块
    chip_w, chip_gap, chip_x = 126, 8, 228
    for i, (title, sub) in enumerate(FIG2_BOARD["debug"]):
        x = chip_x + i * (chip_w + chip_gap)
        b = (x, 486, x + chip_w, 530)
        c.rr(b, STYLE["r_chip"], STYLE["paper"], STYLE["hairline"], 1.0)
        c.block((b[0] + b[2]) / 2, (b[1] + b[3]) / 2,
                [(title, fs["chip"], True, STYLE["ink"], 3),
                 (sub, fs["chip"] - 1.5, False, STYLE["ink_soft"], 0)])

    # --- 四类信号流连线（去交叉重排，端点关系与原图一致） ---
    # 电源流：走供电分区右外侧走廊，绕开分区标题
    c.link([(190, 80), (206, 80), (206, 34), (250, 34)], "amber")
    c.link([(190, 347), (208, 347), (208, 336), (236, 336)], "amber")
    # 图像数据流：摄像头 → 视频采集；核心板内部数据通路
    c.link([(270, 60), (270, 64), (228, 64), (228, 286), (236, 286)], "blue")
    c.link([(430, 187), (448, 187)], "blue", width=1.9)
    c.link([(662, 187), (680, 187)], "blue", width=1.9)
    c.link([(555, 242), (555, 258)], "blue", width=1.9)
    c.link([(333, 242), (333, 258)], "blue", width=1.9)
    # 显示输出流：视频采集 → AN430
    c.link([(430, 270), (438, 270), (438, 120), (750, 120), (750, 60)], "green")
    # 控制与调试流：外设控制 → NPU；核心板 → 调试接口
    c.link([(680, 313), (662, 313)], "violet", width=1.9)
    c.link([(559, 368), (559, 432), (559, 444)], "violet")
    # 调试条内的对齐基线（隐性网格，不含信息）
    c.d.line([(c.P(228), c.P(482)), (c.P(888), c.P(482))],
             fill=STYLE["violet"]["edge"], width=max(1, c.P(0.8)))

    # 图例：等距栅格，线样 / 名称 / 两行说明
    for i, (name, note, tone) in enumerate(FIG2_BOARD["legend"]):
        c.legend_item(932, 84 + i * 88, 240, name, note, tone)
    return c.im


def main():
    ap = argparse.ArgumentParser(description="重绘竞赛报告的两张配图")
    ap.add_argument("--scale", type=int, default=2, help="输出倍率（默认 2）")
    ap.add_argument("--out-dir", default=HERE, help="输出目录")
    ap.add_argument("--only", choices=["fig1", "fig2"], help="只生成其中一张")
    args = ap.parse_args()
    os.makedirs(args.out_dir, exist_ok=True)
    jobs = {
        "fig1": ("fig1_design_flow.png", fig1),
        "fig2": ("fig2_hardware_arch.png", fig2),
    }
    for key, (name, fn) in jobs.items():
        if args.only and args.only != key:
            continue
        im = fn(args.scale)
        path = os.path.join(args.out_dir, name)
        im.save(path, optimize=True)
        print(f"{name}: {im.width}x{im.height} -> {path}")


if __name__ == "__main__":
    main()
