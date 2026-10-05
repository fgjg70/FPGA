#!/usr/bin/env python3
"""fpga_workflow.py - 本工程的统一工作流入口 (校验 / 回归 / 报告)

设计目标: 把 PITFALLS.md 里"反复踩、且静默失败"的坑变成一条命令就能查出来的东西。

  doctor   环境自检: 工具链是否就位, 会话 env 是否需要修复
  check    R1 漂移检测: RTL 清单三处是否同步 / bitstream 新鲜度 / 内存地址 / 编码
  verify   ModelSim 增量回归: 只跑受影响的测试 (内容指纹缓存)
  report   从 results/*.csv 与 fpga/*.rpt 汇总三项指标 + 绝对吞吐

用法:
    python tools/fpga_workflow.py check
    python tools/fpga_workflow.py verify                  # 增量, 跳过未受影响的
    python tools/fpga_workflow.py verify --only tb_units  # 单跑一个
    python tools/fpga_workflow.py verify --force          # 全量重跑
    python tools/fpga_workflow.py report

退出码: 0 = 全部通过, 1 = 有 FAIL/BLOCK, 2 = 用法错误
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time

# --------------------------------------------------------------------------
# 路径常量 (全部用正斜杠, 因为 Vivado/Tcl 只吃正斜杠, 而 Windows 两种都认)
# --------------------------------------------------------------------------
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE).replace("\\", "/")

CACHE_DIR = os.path.join(REPO, ".fpga-cache")
STATE_FILE = os.path.join(CACHE_DIR, "verify-state.json")
LOG_DIR = os.path.join(CACHE_DIR, "logs")

# 工具链 (来自 SKILL.md 第 1 节, 已核实存在)
MSIM = "D:/software/tools/Modelsim/win64"
MSIM_LIC = MSIM + "/LICENSE.TXT"
GCC_BIN = "D:/software/tools/riscv-none-elf/xpack-riscv-none-elf-gcc-15.2.0-1/bin"
GCC = GCC_BIN + "/riscv-none-elf-gcc.exe"
VIVADO = "D:/software/Learn/Xilinx/Vivado/2018.3"
VIVADO_BAT = VIVADO + "/bin/vivado.bat"

PYTHON = sys.executable

# --------------------------------------------------------------------------
# 规范源文件集
# --------------------------------------------------------------------------
# CPU 核: 仓库根目录下的所有 .sv (纯行为级, 零厂商原语)
CORE_EXCLUDE: set[str] = set()
# SoC 侧: 显式列举, 不 glob —— fpga/ 里有大量 Vivado 生成物
SOC_SV = ["fpga/mmio_subsys.sv", "fpga/top_a100t.sv"]

# 已知"在研、尚未接线"的文件: 不被任何模块例化是**预期**的, 报为 info 而非 warn。
# 一旦 P1 (异常/中断 core 接线) 做完, 从这里删掉, 检查会自动开始强制要求。
KNOWN_UNWIRED: set[str] = set()      # csr_file.sv 已于 P1 接入 core, 不再是"在研未接线"

# 每份清单各自应有的集合。差异只在"该有的没有"时报错, 避免把
# "top_a100t 不在 ModelSim 回归里" 这种正常情况误报成问题。
BUILD_FILES = {
    "vivado-score": {
        "path": "fpga/build.tcl",
        "pattern": r"read_verilog\s+-sv\s+\[list\s+(.*?)\]",
        "expected": "rtl",
        "desc": "评分版综合 (非工程模式)",
    },
    "vivado-ila": {
        "path": "fpga/build_ila.tcl",
        "pattern": r"add_files\s+-norecurse\s+\[list\s+(.*?)\]",
        "expected": "rtl",
        "desc": "ILA 调试版综合 (工程模式)",
    },
    "modelsim-coremark": {
        "path": "tools/run_coremark.py",
        "pattern": r"^RTL\s*=\s*\[(.*?)\]",
        "expected": "core",
        "desc": "CoreMark 回归 (ModelSim) —— tb_sw 直接例化 mmio_subsys, 不要 top",
    },
}


# ==========================================================================
# 通用工具
# ==========================================================================
def posix(p: str) -> str:
    return p.replace("\\", "/")


def abspath(rel: str) -> str:
    return posix(os.path.join(REPO, rel))


def read_text(path: str) -> str:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


# CPU 核 RTL 的**编译顺序** —— rv32_pkg 必须第一个编译, 其余模块 import 它。
# 为什么显式列举而不 glob 后排序: 首次跑回归时按字母序把 rv32_pkg 排到了后面,
# vlog 报 60 个 "Could not find the package (rv32_pkg)" —— 顺序是语义, 不是格式。
CORE_SV_ORDER = [
    "rv32_pkg.sv",
    "alu.sv", "branch_unit.sv", "control_unit.sv", "imm_gen.sv", "pc.sv", "regfile.sv",
    "if_id_reg.sv", "id_ex_reg.sv", "ex_mem_reg.sv", "mem_wb_reg.sv",
    "hazard_unit.sv", "load_store_unit.sv",
    "imem.sv", "dmem.sv", "btb.sv", "ras.sv", "muldiv.sv", "csr_file.sv",
    "core.sv",
]


def discover_core_sv() -> list[str]:
    """CPU 核 RTL, 按编译顺序返回 (rv32_pkg 在最前)。"""
    out = [f for f in CORE_SV_ORDER if os.path.isfile(os.path.join(REPO, f))]
    # 兜底: 仓库里新出现的、还没登记进 CORE_SV_ORDER 的核文件
    known = set(CORE_SV_ORDER)
    for name in sorted(os.listdir(REPO)):
        if (name.endswith(".sv") and name not in known
                and os.path.isfile(os.path.join(REPO, name))):
            out.append(name)
    return out


def unregistered_core_sv() -> list[str]:
    """仓库根目录存在、但没登记进 CORE_SV_ORDER 的 .sv (check 会报出来)。"""
    known = set(CORE_SV_ORDER)
    return sorted(
        n for n in os.listdir(REPO)
        if n.endswith(".sv") and n not in known and os.path.isfile(os.path.join(REPO, n))
    )


def canonical_rtl() -> list[str]:
    """本工程全部综合用 RTL 源文件。"""
    return discover_core_sv() + SOC_SV


MODULE_RE = re.compile(r"^\s*module\s+([A-Za-z_]\w*)", re.M)
INST_RE = re.compile(r"^\s*([A-Za-z_]\w*)\s*(?:#\s*\([^;]*?\)\s*)?([A-Za-z_]\w*)\s*\(", re.M)


def declared_modules(rel: str) -> list[str]:
    try:
        return MODULE_RE.findall(read_text(abspath(rel)))
    except OSError:
        return []


def declared_in_any(module: str, files: list[str]) -> bool:
    return any(module in declared_modules(f) for f in files)


def all_sv_sources() -> list[str]:
    """所有会被编译的 SV 源文件 (RTL + tb), 用于判断"某模块是否真的被例化过"。"""
    out = list(canonical_rtl())
    simdir = os.path.join(REPO, "sim")
    if os.path.isdir(simdir):
        for n in sorted(os.listdir(simdir)):
            if n.endswith(".sv"):
                out.append("sim/" + n)
    return out


def instantiated_modules() -> set[str]:
    """扫描所有 SV 源, 收集被例化的模块名。

    注意端口列表可能跨行 (tb_sw.sv 就是 .clk (clk),\\n .rst (rst), ...),
    所以用 DOTALL 版的非贪婪匹配, 不能只看单行。
    """
    used: set[str] = set()
    for f in all_sv_sources():
        try:
            txt = read_text(abspath(f))
        except OSError:
            continue
        # 去掉 // 行注释, 免得把注释里的模块名当例化
        txt = re.sub(r"//[^\n]*", "", txt)
        for m in re.finditer(r"^\s*([A-Za-z_]\w*)\s*(?:#\s*\(.*?\)\s*)?([A-Za-z_]\w*)\s*\(",
                            txt, re.M | re.S):
            used.add(m.group(1))
    return used


def parse_tcl_list(path: str, pattern: str) -> list[str] | None:
    """从 .tcl / .py 里抽出文件清单, 返回相对仓库根的 posix 路径。"""
    try:
        text = read_text(abspath(path))
    except OSError:
        return None
    if path.endswith(".py"):
        # Python: 抽 '单引号字符串'
        m = re.search(pattern, text, re.M | re.S)
        if not m:
            return None
        items = re.findall(r"['\"]([^'\"]+\.sv)['\"]", m.group(1))
    else:
        m = re.search(pattern, text, re.M | re.S)
        if not m:
            return None
        items = re.findall(r'"([^"]+\.sv)"', m.group(1))
    out = []
    for it in items:
        p = posix(it)
        if os.path.isabs(p):
            p = posix(os.path.relpath(p, REPO))
        out.append(p)
    return out


# ==========================================================================
# 子进程执行: 恢复被剥离的会话环境
# ==========================================================================
def clean_env() -> dict:
    """DSH 会话的 process.env 是空的, 必须显式补齐, 否则 Vivado/ModelSim 都会失败。

    两个具体故障 (SKILL.md 第 2 节):
      - 缺 PROCESSOR_ARCHITECTURE -> Vivado 报 "32-bit platform is not supported"
      - 缺 LM_LICENSE_FILE        -> vsim 报 "Unable to checkout a license"
    """
    env = {
        "SystemRoot": r"C:\Windows",
        "windir": r"C:\Windows",
        "SystemDrive": "C:",
        "COMSPEC": r"C:\Windows\System32\cmd.exe",
        "PATHEXT": ".COM;.EXE;.BAT;.CMD",
        "PROCESSOR_ARCHITECTURE": "AMD64",
        "PROCESSOR_IDENTIFIER": "AMD64",
        "TEMP": tempfile.gettempdir(),
        "TMP": tempfile.gettempdir(),
        "USERPROFILE": os.path.expanduser("~"),
        "HOME": os.path.expanduser("~"),
        "NUMBER_OF_PROCESSORS": str(os.cpu_count() or 1),
        "OS": "Windows_NT",
        # powershell 不在精简 PATH 中, 显式补上
        "PATH": os.pathsep.join([
            MSIM,
            GCC_BIN,
            r"C:\Windows\System32",
            r"C:\Windows\System32\WindowsPowerShell\v1.0",
            r"C:\Windows",
        ]),
    }
    # 继承父进程里非空的值 (交互式运行时通常已经有了)
    for k, v in os.environ.items():
        if v:
            env[k] = v
    env["LM_LICENSE_FILE"] = MSIM_LIC
    env["MGLS_LICENSE_FILE"] = MSIM_LIC
    env["PATH"] = MSIM + os.pathsep + GCC_BIN + os.pathsep + env.get("PATH", "")
    return env


def run(cmd, cwd=None, timeout=1800, env=None):
    """执行命令, 返回 (returncode, 合并输出, 墙钟秒数)。"""
    t0 = time.time()
    try:
        r = subprocess.run(
            cmd, cwd=cwd, env=env or clean_env(), capture_output=True,
            text=True, errors="replace", timeout=timeout,
        )
        return r.returncode, (r.stdout or "") + (r.stderr or ""), time.time() - t0
    except subprocess.TimeoutExpired as e:
        out = ((e.stdout or b"").decode("utf-8", "replace") if isinstance(e.stdout, bytes)
               else (e.stdout or ""))
        return 124, out + f"\n!! TIMEOUT after {timeout}s\n", time.time() - t0
    except FileNotFoundError as e:
        return 127, f"!! 找不到可执行文件: {e}\n", time.time() - t0


# ==========================================================================
# 内存布局契约 (PITFALLS R1 —— 改 link.ld 要同步 5 类文件)
# ==========================================================================
def check_memory_layout() -> list[dict]:
    """核对 link.ld 里的地址常量是否与 RTL / tb 同步。"""
    findings = []
    ld_path = "sw/link.ld"
    try:
        ld = read_text(abspath(ld_path))
    except OSError:
        return [{"sev": "FAIL", "msg": f"读不到 {ld_path}"}]

    def ld_value(name):
        m = re.search(name + r"\s*=\s*(0x[0-9A-Fa-f_]+)", ld)
        return int(m.group(1).replace("_", ""), 16) if m else None

    tohost_ld = ld_value(r"__tohost_addr|tohost")
    log_ld = ld_value(r"__log_start|log_start")

    # tb_sw.sv 的 TOHOST_ADDR 是 DMEM_BASE + 0x2000, 注释里还写着旧值 0x90001000
    for rel, pat, expect_name in [
        ("sim/tb_sw.sv", r"TOHOST_ADDR\s*=\s*DMEM_BASE\s*\+\s*32'h([0-9A-Fa-f_]+)", "tohost offset"),
    ]:
        try:
            txt = read_text(abspath(rel))
        except OSError:
            continue
        m = re.search(pat, txt)
        if m:
            off = int(m.group(1).replace("_", ""), 16)
            findings.append({
                "sev": "INFO",
                "msg": f"{rel}: {expect_name} = 0x{off:04X} (TOHOST = DMEM_BASE + 0x{off:X})",
            })
        # 注释里的旧地址: 行注释里出现 0x9000_1000 而代码已用 0x2000
        stale = re.findall(r"//.*?(0x9000[0-9A-Fa-f_]{4})", txt)
        for s in set(stale):
            val = int(s.replace("_", ""), 16)
            if val == 0x90001000 and m and int(m.group(1).replace("_", ""), 16) != 0x1000:
                findings.append({
                    "sev": "WARN",
                    "msg": f"{rel}: 注释里写着旧 tohost 0x90001000, 代码已改用 "
                           f"DMEM_BASE+0x{m.group(1)} —— 注释该更新了 (会误导下一个人)",
                })

    # dmem 空间 ASSERT 守卫: CoreMark .data+.bss 正好用满 4KB
    if "ASSERT" in ld:
        findings.append({"sev": "INFO", "msg": f"{ld_path}: 有 ASSERT 守卫 (布局溢出会在链接期暴露)"})
    else:
        findings.append({"sev": "WARN", "msg": f"{ld_path}: 没有 ASSERT 守卫, 布局溢出会静默"})

    if tohost_ld is None:
        findings.append({
            "sev": "WARN",
            "msg": f"{ld_path}: 没找到 tohost 的 PROVIDE 定义 (tb 靠绝对地址约定, 找不到就无法机器核对)",
        })
    return findings


def _sw_source_files() -> list[str]:
    """sw/ 下参与镜像构建的源文件 (C / S / 链接脚本)。"""
    out = []
    for d in ("sw", "sw/coremark"):
        dd = abspath(d)
        if os.path.isdir(dd):
            for n in sorted(os.listdir(dd)):
                if n.endswith((".c", ".h", ".S", ".ld")):
                    out.append(f"{d}/{n}")
    return out


def _sw_source_hash() -> str:
    """sw/ 源码的内容哈希 -> 用于判断镜像是否需要重建。"""
    h = hashlib.sha256()
    for rel in _sw_source_files():
        p = abspath(rel)
        h.update(rel.encode())
        h.update(sha256_file(p).encode() if os.path.exists(p) else b"MISSING")
    return h.hexdigest()[:32]


def _newest_sw_mtime() -> float:
    newest = 0.0
    for rel in _sw_source_files():
        p = abspath(rel)
        if os.path.exists(p):
            newest = max(newest, os.path.getmtime(p))
    return newest


def check_bitstream_freshness() -> list[dict]:
    """bitstream 新鲜度: 评分版 .bit 是否比 RTL / 程序镜像旧。

    为什么单列一项: imem/dmem 是**综合时**由 $readmemh 装进去的, 所以
    "改了软件 -> 只重建 .hex" 是不够的, 必须重新综合。这个坑曾经让板卡上
    跑的是旧程序镜像而不自知 —— 而且症状是"结果完全一致", 极易误判成通过。
    """
    out: list[dict] = []
    bit = abspath("fpga/cpu_a100t.bit")
    if not os.path.exists(bit):
        return [{"sev": "WARN", "msg": "fpga/cpu_a100t.bit 不存在 (还没构建过评分版?)"}]
    bit_t = os.path.getmtime(bit)

    # 评分版构建脚本里用哪个程序镜像。
    # build.tcl 现在是参数化的 (set PROG / set imem / set dmem), 所以不能只认
    # 字面量 `DMEM_INIT_FILE="..."` —— 那种写法在重构后会变成假报警。
    # 改为: 先看 verilog_define 那行到底传了哪几个宏, 再把 $imem/$dmem 解析成
    # 真实路径 (PROG 默认值 + 路径模板)。
    tcl = read_text(abspath("fpga/build.tcl"))
    m_prog = re.search(r"^set PROG\s+(\S+)\s*$", tcl, re.M)
    prog = m_prog.group(1) if m_prog else None
    has_imem = "IMEM_INIT_FILE" in tcl
    has_dmem = "DMEM_INIT_FILE" in tcl

    def resolve(var: str) -> str | None:
        """把 `set <var> "$root/sim/prog/$PROG.hex"` 解析成仓库相对路径。"""
        m = re.search(r'^set\s+' + var + r'\s+"([^"]+)"', tcl, re.M)
        if not m or not prog:
            return None
        p = m.group(1).replace("$root", "D:/USER/Desktop/FPGA/FPGA").replace("$PROG", prog)
        return posix(os.path.relpath(p, REPO))

    imem_img, dmem_img = resolve("imem"), resolve("dmem")

    if not has_dmem:
        out.append({
            "sev": "FAIL",
            "msg": "fpga/build.tcl 没有把 DMEM_INIT_FILE 传给 synth_design —— "
                   "本核是哈佛结构, .data/.rodata 靠 dmem 自己的镜像装入, "
                   "不传就跑不了真正的程序 (P0)",
        })
    if not has_imem:
        out.append({"sev": "FAIL", "msg": "fpga/build.tcl 没有传 IMEM_INIT_FILE"})
    if dmem_img and not os.path.exists(abspath(dmem_img)):
        out.append({
            "sev": "FAIL",
            "msg": f"build.tcl 指定的 dmem 镜像不存在: {dmem_img} "
                   f"(综合会因 file exists 守卫直接失败, 但先在此报出来更省事)",
        })
    if imem_img and not imem_img.endswith("cm_hw.hex"):
        out.append({
            "sev": "WARN",
            "msg": f"评分版装的是 {imem_img}, 不是跑分程序 cm_hw.hex —— "
                   f"这个 bitstream 上板跑不出 CoreMark 分数 (P0)",
        })

    # 比 bit 新的输入文件。
    # 【镜像用内容哈希判据, 不用 mtime】—— 重建一份"逐字节相同"的镜像会让 mtime
    # 变新, 用 mtime 就会误报 stale。synth 每次构建会记下当时用的镜像哈希,
    # 哈希没变就说明 bitstream 里的程序镜像仍然对得上。
    newer = []
    inputs = canonical_rtl() + [
        "fpga/top_a100t.sv", "fpga/mmio_subsys.sv", "fpga/daVinciPro.xdc",
    ]
    for f in inputs:
        fp = abspath(f)
        if os.path.exists(fp) and os.path.getmtime(fp) > bit_t:
            newer.append(f)

    try:
        sc = json.loads(read_text(os.path.join(CACHE_DIR, "synth-cache.json")))
        rec = sc.get("image_hash", {}).get(prog)
    except Exception:
        rec = None
    for label, rel in (("imem", imem_img), ("dmem", dmem_img)):
        if not rel or not os.path.exists(abspath(rel)):
            continue
        cur = sha256_file(abspath(rel))
        if rec and rec.get(label) == cur:
            # 内容与上次综合时一致 -> 即使 mtime 更新也不算 stale
            continue
        if os.path.getmtime(abspath(rel)) > bit_t:
            newer.append(f"{rel}  (内容已变)")

    if newer:
        shown = ", ".join(newer[:6]) + (" ..." if len(newer) > 6 else "")
        out.append({
            "sev": "FAIL",
            "msg": f"bitstream 比 {len(newer)} 个输入文件旧 -> 板上跑的不是当前代码 "
                   f"({shown})",
        })
    else:
        out.append({
            "sev": "INFO",
            "msg": f"bitstream 比所有输入新 "
                   f"({os.path.getsize(bit)//1024} KB, {time.strftime('%m-%d %H:%M', time.localtime(bit_t))})",
        })
    if imem_img:
        out.append({
            "sev": "INFO",
            "msg": f"评分版程序镜像: imem={imem_img}"
                   + (f", dmem={dmem_img}" if dmem_img else ", dmem=(未定义)"),
        })
    return out


# ==========================================================================
# check: R1 漂移检测
# ==========================================================================
def cmd_check(args) -> int:
    print("=" * 74)
    print("  R1 漂移检测  (PITFALLS: 改了 A 忘了同步 B —— 全部静默失败)")
    print("=" * 74)

    canon = canonical_rtl()
    canon_set = set(canon)
    problems: list[str] = []
    warnings: list[str] = []

    # ---- 1. 三处 RTL 清单 ----
    print(f"\n[1] RTL 文件清单  (规范集 = {len(canon)} 个文件)")
    core_set = set(discover_core_sv())
    listed_sets: dict[str, set[str]] = {}
    for key, spec in BUILD_FILES.items():
        expect = core_set if spec["expected"] == "core" else canon_set
        listed = parse_tcl_list(spec["path"], spec["pattern"])
        if listed is None:
            problems.append(f"{spec['path']}: 解析不出文件清单 (正则失效? 文件被改写了?)")
            print(f"  ??   {key:18s} {spec['path']:26s} 解析失败")
            continue
        listed_sets[key] = set(listed)
        missing = [f for f in canon if f in expect and f not in listed]
        extra = [f for f in listed if f not in canon_set]
        flag = "OK " if not missing and not extra else "!! "
        print(f"  {flag} {key:18s} {spec['path']:26s} {len(listed):2d} 项"
              + (f"  缺 {len(missing)}" if missing else "")
              + (f"  多 {len(extra)}" if extra else ""))
        for f in missing:
            mods = declared_modules(f)
            if f in KNOWN_UNWIRED:
                print(f"       [info] 缺 {f}  ({','.join(mods)} 尚未接线, P1 待办) -> 暂不强制")
            else:
                problems.append(f"{spec['path']} 缺少 {f} (模块 {','.join(mods)})")
                print(f"       [FAIL] 缺 {f}  模块 {','.join(mods)} -> 必须补进清单")
        for f in extra:
            problems.append(f"{spec['path']} 列了不存在的文件 {f}")
            print(f"       [FAIL] 多 {f}  (文件已不存在)")

    # 清单之间的互相漂移: 在 A 里有、在 B 里没有 —— 这是最典型的 R1 静默失败
    if len(listed_sets) >= 2:
        for a in listed_sets:
            for b in listed_sets:
                if a >= b:
                    continue
                only_a = listed_sets[a] - listed_sets[b]
                # 只在"两者本应一致"的文件上报警: 即 CPU 核文件
                only_a = {f for f in only_a if f in core_set}
                if only_a:
                    problems.append(
                        f"{BUILD_FILES[a]['path']} 有而 {BUILD_FILES[b]['path']} 没有: "
                        + ", ".join(sorted(only_a)))
                    print(f"       [FAIL] 清单互相漂移: {a} 有 {sorted(only_a)}, 但 {b} 没有")

    # ---- 2. 未接线模块 ----
    print("\n[2] 未接线模块 (RTL 存在但没有任何地方例化它)")
    unreg = unregistered_core_sv()
    if unreg:
        for f in unreg:
            print(f"  [FAIL] {f}: 仓库里存在但没登记进 tools/fpga_workflow.py 的 CORE_SV_ORDER")
            problems.append(f"{f} 未登记进 CORE_SV_ORDER -> 回归和检查都会漏掉它")
    used = instantiated_modules()
    unwired = []
    for f in canon:
        mods = [m for m in declared_modules(f) if m != "rv32_pkg"]
        # top 是顶层, 天然不会被例化
        if f.endswith("top_a100t.sv"):
            continue
        for mod in mods:
            if mod not in used:
                unwired.append((f, mod))
    if unwired:
        for f, mod in unwired:
            if f in KNOWN_UNWIRED:
                print(f"  [info] {f}: 模块 {mod} 未接线 (已知在研, P1 待办)")
            else:
                print(f"  [warn] {f}: 模块 {mod} 没有被任何地方例化")
                warnings.append(f"{f}:{mod} 未接线")
    else:
        print("  OK   所有 RTL 模块都被例化")

    # ---- 3. 软件 -> 镜像 新鲜度 ----
    # 【判据用内容哈希, 不用 mtime】(HANDOFF-WORKFLOW.md §5)
    # 踩过: 把 link.ld 改回原样(mtime 变了、内容没变) 就误报"镜像过期"。
    # mtime 会被 checkout/复制/改回原样打乱, 只有内容才算数。
    print("\n[3] 软件源 -> .hex 镜像 新鲜度 (内容哈希判据)")
    sw_hash = _sw_source_hash()
    hcache_path = os.path.join(CACHE_DIR, "sw-build.json")
    try:
        hcache = json.loads(read_text(hcache_path))
    except Exception:
        hcache = {}
    pairs = [
        ("sim/prog/hello.hex", "hello"),
        ("sim/prog/cm_rv32im.hex", "coremark"),
        ("sim/prog/cm_hw.hex", "coremark"),
    ]
    for img, group in pairs:
        ip = abspath(img)
        if not os.path.exists(ip):
            print(f"  [warn] {img} 不存在")
            warnings.append(f"{img} 不存在")
            continue
        built = hcache.get(group)
        if built is None:
            # 没有记录: 退回 mtime 比较, 但明确说明这是弱判据
            if os.path.getmtime(ip) < _newest_sw_mtime():
                print(f"  [warn] {img}: 无内容基线可比, 且比 sw/ 源文件旧 (建议重建)")
                warnings.append(f"{img} 可能过期 (无基线)")
            else:
                print(f"  OK    {img} (无内容基线, mtime 更新)")
            continue
        if built != sw_hash:
            print(f"  [FAIL] {img}: sw/ 源码内容已变 -> 需要重建镜像 "
                  f"(重跑 tools/build_sw.py 或 tools/asm.py)")
            problems.append(f"{img} 过期")
        else:
            print(f"  OK    {img} 与当前 sw/ 源码内容一致")

    # ---- 4. bitstream 新鲜度 ----
    print("\n[4] bitstream 新鲜度  (imem/dmem 是综合时装进去的, 改软件必须重新综合)")
    for f in check_bitstream_freshness():
        tag = {"FAIL": "[FAIL]", "WARN": "[warn]", "INFO": "  ok  "}[f["sev"]]
        print(f"  {tag} {f['msg']}")
        if f["sev"] == "FAIL":
            problems.append(f["msg"])
        elif f["sev"] == "WARN":
            warnings.append(f["msg"])

    # ---- 5. 内存布局 ----
    print("\n[5] 内存布局同步")
    for f in check_memory_layout():
        tag = {"FAIL": "[FAIL]", "WARN": "[warn]", "INFO": "  ok  "}[f["sev"]]
        print(f"  {tag} {f['msg']}")
        if f["sev"] == "FAIL":
            problems.append(f["msg"])
        elif f["sev"] == "WARN":
            warnings.append(f["msg"])

    # ---- 6. 文本编码 (R2) ----
    print("\n[6] .bat / .tcl 纯 ASCII 检查")
    print("      .bat: cmd 用 OEM 代码页解析 -> 中文会吃掉每行首字符 (硬故障, 必须修)")
    print("      .tcl: Vivado 对非 ASCII 注释敏感 -> 埋雷, 下次改动该文件时很危险")
    bat_bad, tcl_bad = [], []
    for root, dirs, files in os.walk(REPO):
        dirs[:] = [d for d in dirs if d not in (".git", ".fpga-cache", "ila_proj.runs",
                                                "ila_proj.cache", "ila_proj.srcs", ".Xil", "msim")]
        for n in files:
            low = n.lower()
            if not low.endswith((".bat", ".tcl")):
                continue
            p = os.path.join(root, n)
            try:
                with open(p, "rb") as fh:
                    raw = fh.read()
            except OSError:
                continue
            # 含 >127 的字节即非 ASCII (UTF-8 中文 / 7 位掩码残留都算)
            if any(b > 127 for b in raw):
                first = next(i for i, b in enumerate(raw) if b > 127)
                line = raw[:first].count(b"\n") + 1
                loc = "%s:%d" % (posix(os.path.relpath(p, REPO)), line)
                (bat_bad if low.endswith(".bat") else tcl_bad).append(loc)
    for b in bat_bad:
        print("  [FAIL] .bat 有非 ASCII: %s   <- 会直接报 'et 不是内部或外部命令'" % b)
        problems.append(".bat 非 ASCII: " + b)
    for b in tcl_bad:
        print("  [warn] .tcl 有非 ASCII: %s   (当前构建可用; 建议下次改动时转成 ASCII)" % b)
        warnings.append(".tcl 非 ASCII: " + b)
    if not bat_bad and not tcl_bad:
        print("  OK    所有 .bat/.tcl 都是纯 ASCII")

    # ---- 汇总 ----
    print("\n" + "=" * 74)
    if problems:
        print(f"  结论: {len(problems)} 个必须修的问题, {len(warnings)} 个提醒")
        for p in problems:
            print(f"    [FAIL] {p}")
        print("=" * 74)
        return 1
    print(f"  结论: 同步检查通过 ({len(warnings)} 个非阻塞提醒)")
    print("=" * 74)
    return 0


# ==========================================================================
# verify: ModelSim 增量回归
# ==========================================================================
def test_matrix() -> list[dict]:
    """回归矩阵。rtl 用 'rtl' 表示全集, 'core' 表示仅 CPU 核 (不含 mmio/top)。"""
    core = discover_core_sv()
    return [
        {"name": "tb_units", "rtl": core, "tb": "sim/tb_units.sv",
         "plus": [], "max_cycles": None, "timeout": 300, "desc": "194 项单元检查"},
        {"name": "tb_core_basic", "top": "tb_core", "rtl": "rtl", "tb": "sim/tb_core.sv",
         "imem": "sim/prog/basic.hex",
         "plus": [], "max_cycles": 200000, "timeout": 600, "desc": "系统级自校验"},
        {"name": "tb_core_trap", "top": "tb_core", "rtl": "rtl", "tb": "sim/tb_core.sv",
         "imem": "sim/prog/trap.hex",
         # +illegal_trace 打开陷阱诊断探针 —— 这个测试讨论的就是陷阱语义,
         # 出问题时需要逐拍证据 (完整输出在 .fpga-cache/logs/tb_core_trap.log)。
         "plus": ["+illegal_trace"], "max_cycles": 200000, "timeout": 600,
         "desc": "异常/中断自校验 (Zicsr + 陷阱 + MRET)"},
        # 【必须用 tb_soc / tb_sw】tb_core 不接外设 (ext_rdata 恒 0、irq_timer 恒 0),
        # 定时器测试需要 mmio_subsys 真的在位, 否则 MMIO 读回 0、中断永远不来。
        {"name": "tb_soc_timer_irq", "top": "tb_soc", "rtl": "rtl", "tb": "sim/tb_soc.sv",
         "imem": "sim/prog/timer_irq.hex",
         "plus": [], "max_cycles": 200000, "timeout": 600,
         "desc": "P2 定时器中断 (mtime/mtimecmp -> mip.MTIP)"},
        {"name": "tb_core_m_ext", "top": "tb_core", "rtl": "rtl", "tb": "sim/tb_core.sv",
         "imem": "sim/prog/m_ext.hex", "plus": [], "max_cycles": 200000, "timeout": 600,
         "desc": "RV32M 边界"},
        {"name": "tb_soc", "top": "tb_soc", "rtl": "rtl", "tb": "sim/tb_soc.sv",
         "imem": "sim/prog/mmio.hex", "plus": [], "max_cycles": 400000, "timeout": 600,
         "desc": "外设 + UART 环回"},
        {"name": "tb_sw_hello", "top": "tb_sw", "rtl": "rtl", "tb": "sim/tb_sw.sv",
         "imem": "sim/prog/hello.hex", "dmem": "sim/prog/hello.dmem.hex",
         "plus": [], "max_cycles": 400000, "timeout": 600, "desc": "裸机 hello"},
        {"name": "tb_sw_coremark", "top": "tb_sw", "rtl": "rtl", "tb": "sim/tb_sw.sv",
         "imem": "sim/prog/cm_rv32im.hex", "dmem": "sim/prog/cm_rv32im.dmem.hex",
         "plus": [], "max_cycles": 5000000, "timeout": 1200, "desc": "CoreMark 仿真"},
        # 应用场景: 神经网络推理的 GEMM 核心。当前是"软件基线", 加了加速单元后
        # 同一程序走加速路径, 加速比才有可比基准。
        {"name": "tb_sw_nn_demo", "top": "tb_sw", "rtl": "rtl", "tb": "sim/tb_sw.sv",
         "imem": "sim/prog/nn_demo.hex", "dmem": "sim/prog/nn_demo.dmem.hex",
         "plus": [], "max_cycles": 3000000, "timeout": 900,
         "desc": "应用场景: 神经网络 GEMM 核心"},
    ]


def test_fingerprint(t: dict) -> str:
    """一个测试的缓存键 = 参与编译/运行的所有文件内容哈希 + 参数。"""
    h = hashlib.sha256()
    files = t["rtl"] if isinstance(t["rtl"], list) else canonical_rtl()
    for f in files + [t["tb"]]:
        p = abspath(f)
        h.update(f.encode())
        h.update(sha256_file(p).encode() if os.path.exists(p) else b"MISSING")
    for key in ("imem", "dmem"):
        if t.get(key):
            p = abspath(t[key])
            h.update(key.encode())
            h.update(sha256_file(p).encode() if os.path.exists(p) else b"MISSING")
    h.update(json.dumps({k: t.get(k) for k in ("plus", "max_cycles")}, sort_keys=True).encode())
    h.update(("gcc=" + gcc_version()).encode())
    return h.hexdigest()[:32]


_GCC_VER: str | None = None


def gcc_version() -> str:
    global _GCC_VER
    if _GCC_VER is None:
        rc, out, _ = run([GCC, "--version"], timeout=60)
        _GCC_VER = out.splitlines()[0] if rc == 0 and out else "unknown"
    return _GCC_VER


def load_state() -> dict:
    try:
        return json.loads(read_text(STATE_FILE))
    except Exception:
        return {}


def save_state(state: dict) -> None:
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(STATE_FILE, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=1, ensure_ascii=False)


SIM_CACHE: dict[str, str] = {}


def compile_sim(rtl_files: list[str], tb: str, defines: tuple[str, ...] = ()) -> tuple[int, str, str]:
    """vlib + vlog, 结果按 (文件集, 内容, defines) 缓存到各测试自己的 work 目录。"""
    key = hashlib.sha256(
        ("".join(rtl_files) + tb + "|".join(defines) + "".join(
            sha256_file(abspath(f)) for f in rtl_files + [tb] if os.path.exists(abspath(f)))
         ).encode()
    ).hexdigest()[:16]
    workdir = os.path.join(CACHE_DIR, "sim", key)
    if SIM_CACHE.get(key) == "ok":
        return 0, "(cached)", workdir
    os.makedirs(workdir, exist_ok=True)
    srcs = [abspath(f) for f in rtl_files] + [abspath(tb)]
    vlib = os.path.join(MSIM, "vlib.exe")
    vlog = os.path.join(MSIM, "vlog.exe")
    rc, out, _ = run([vlib, "work"], cwd=workdir)
    if rc != 0:
        return rc, out, workdir
    # 【必须写成 +define+NAME, 不能写 +NAME】
    # 实测: `vlog -sv +FOO ...` 里 `+FOO` 会被当成未知选项 —— 宏**根本不会被定义**,
    # 而编译还"成功"(只报个错然后继续), 于是仿真跑的是**没开宏的版本**。
    # 这个坑静默了很久: IMEM_REG_READ / LOAD_RESULT_REG / BTB_GSHARE 三个宏
    # 在 ModelSim 侧**从来没生效过** —— 综合(Tcl 的 -verilog_define)开了, 仿真没开,
    # 两边跑的不是同一份设计。见 PITFALLS R17。
    # 自证手段: 每个宏生效时该模块会 $display 一行 (如 "[btb] GSHARE ... ACTIVE")。
    flags = [(d if d.startswith("+define+") else "+define+" + d.lstrip("+")) for d in defines]
    rc, out2, _ = run([vlog, "-sv"] + flags + ["-work", "work"] + srcs, cwd=workdir)
    if rc == 0:
        SIM_CACHE[key] = "ok"
    return rc, out + out2, workdir


def cmd_verify(args) -> int:
    only = set(args.only) if args.only else None
    matrix = [t for t in test_matrix() if not only or t["name"] in only]

    print("=" * 74)
    print("  ModelSim 增量回归")
    print(f"  RTL 规范集 {len(canonical_rtl())} 个文件 | 工具 {MSIM}")
    print("=" * 74)

    if not os.path.exists(os.path.join(MSIM, "vsim.exe")):
        print(f"  [BLOCK] 找不到 {MSIM}/vsim.exe")
        return 1

    state = load_state()
    results = []

    for t in matrix:
        name = t["name"]
        files = t["rtl"] if isinstance(t["rtl"], list) else canonical_rtl()

        # 前置文件检查
        missing = [f for f in files + [t["tb"]] if not os.path.exists(abspath(f))]
        if missing:
            print(f"\n--- {name}: [BLOCK] 缺文件 {missing}")
            results.append((name, "BLOCK", 0, "缺文件 " + ",".join(missing)))
            continue

        fp = test_fingerprint(t)
        prev = state.get(name, {})
        # XFAIL 类的测试永远重跑: 它记录的是"还没做"的状态, 一旦 RTL 接线完成就该
        # 从 XFAIL 翻成 XPASS, 缓存命中会把那个翻转发掩盖掉。
        if (not args.force and prev.get("fingerprint") == fp
                and not t.get("expect_fail_ok")):
            print(f"\n--- {name}: [SKIP] 未受影响 (上次 {prev.get('status')}, "
                  f"{prev.get('seconds', 0):.1f}s)")
            results.append((name, "SKIP", 0, f"缓存命中 (上次 {prev.get('status')})"))
            continue

        print(f"\n--- {name}: {t['desc']}")
        t0 = time.time()
        # 【默认三个宏全关】= 上板验证过的配置 (ILA 版 bitstream)。
        # 三个宏都曾默认为开, 但那是基于无效实验 —— ModelSim 侧宏传递写错
        # (见 PITFALLS R17), 宏从未在仿真生效, 所以零代价是假的。
        # 修好后实测: IMEM_REG_READ / LOAD_RESULT_REG 单独开会 timeout;
        # BTB_GSHARE 能跑但慢 6%。要用请显式加 --gshare / --reg-read / --load-reg。
        defs = []
        if args.imem_reg_read:
            defs.append("IMEM_REG_READ")
        if args.load_reg:
            defs.append("LOAD_RESULT_REG")
        if args.gshare:
            defs.append("BTB_GSHARE")
        if args.ras:
            # 返回地址栈。实测有效但不划算 (CoreMark/MHz +0.38% 换 fmax -2.8%),
            # 故默认关闭 —— 见 results/p4-ras.md
            defs.append("RAS_EN")
        defines = tuple(defs)
        rc, out, workdir = compile_sim(files, t["tb"], defines)
        if rc != 0:
            print(f"    [FAIL] 编译失败 (vlog)")
            print(_indent(_vlog_errors(out)))
            results.append((name, "FAIL", time.time() - t0, "vlog 编译失败"))
            state[name] = {"fingerprint": fp, "status": "FAIL-COMPILE",
                           "seconds": time.time() - t0}
            save_state(state)
            continue

        vsim = os.path.join(MSIM, "vsim.exe")
        top = t.get("top", t["tb"].split("/")[-1][:-3])
        cmd = [vsim, "-c", "-do", "run -all; quit -f", "work." + top]
        # -sv_seed / defines 对 vsim 也要给, 否则 $test$plusargs 之外的宏不一致
        for d in defines:
            cmd.insert(1, "+define+" + d)

        blocked = None
        for key, plus in (("imem", "+imem="), ("dmem", "+dmem=")):
            if not t.get(key):
                continue
            if not os.path.exists(abspath(t[key])):
                if t.get(key + "_optional"):
                    print(f"    (跳过可选输入 {t[key]}: 不存在 —— 该测试台不用 dmem 镜像)")
                    continue
                blocked = f"缺镜像 {t[key]} (先跑 tools/build_sw.py)"
                break
            cmd.append(plus + abspath(t[key]))
        if blocked:
            print(f"    [BLOCK] {blocked}")
            results.append((name, "BLOCK", time.time() - t0, blocked))
            continue

        for p in t.get("plus", []):
            cmd.append(p)
        if t.get("max_cycles"):
            cmd.append(f"+max_cycles={t['max_cycles']}")

        rc, out2, _ = run(cmd, cwd=workdir, timeout=t["timeout"])
        dt = time.time() - t0

        # ---- 判定 ----
        # 依据是 testbench 自己打印的结论行, 不是 vsim 的退出码 ——
        # ModelSim 用 `quit -f` 结束时无论测试成败都返回 0。四个 tb 在成功时
        # 都会打印 "RESULT : PASS", 所以要求它**显式出现** (白名单, 不是黑名单):
        # 之前用 `"PASS" in out.upper()` 会把编译失败/超时误判成通过。
        saw_pass = "RESULT : PASS" in out2
        crashed = ("** Error" in out2) or ("Fatal" in out2)
        timed_out = "TIMEOUT after" in out2
        got_pass = saw_pass and not crashed and not timed_out

        xfail = t.get("expect_fail_ok", False)
        if xfail:
            status = "XFAIL" if not got_pass else "XPASS"
        else:
            status = "PASS" if got_pass else "FAIL"

        note = ""
        if not got_pass:
            note = _clean(_first_failure(out2)) or ("超时" if timed_out else "无 RESULT : PASS")
        print(f"    [{status}] {dt:.1f}s  rc={rc}  {note}")
        if status in ("FAIL", "XPASS") or args.verbose:
            print(_indent(_tail_interesting(out2)))

        results.append((name, status, dt, note))
        state[name] = {"fingerprint": fp, "status": status, "seconds": dt}
        save_state(state)
        os.makedirs(LOG_DIR, exist_ok=True)
        with open(os.path.join(LOG_DIR, name + ".log"), "w", encoding="utf-8") as f:
            f.write(out2)

    # ---- 汇总 ----
    print("\n" + "=" * 74)
    print("  回归汇总")
    print("=" * 74)
    counts = {}
    for name, status, dt, note in results:
        counts[status] = counts.get(status, 0) + 1
        print(f"  {status:6s} {name:18s} {dt:7.1f}s  {note}")
    print("\n  " + " | ".join(f"{k} {v}" for k, v in sorted(counts.items())))
    if counts.get("XFAIL"):
        print("  XFAIL = 预期失败 (P1 接线尚未做); XPASS = 该更新 expect_fail_ok 了")
    print("=" * 74)
    # XPASS 也要算异常: 说明预期已经过时
    bad = counts.get("FAIL", 0) + counts.get("BLOCK", 0) + counts.get("XPASS", 0)
    return 1 if bad else 0


def _vlog_errors(out: str, limit: int = 12) -> str:
    """只挑 vlog 的真错误行, 别把 60 行级联错误全刷出来。"""
    errs, seen = [], set()
    for ln in out.splitlines():
        if "** Error" in ln:
            key = ln.split("):")[-1].strip()
            if key not in seen:
                seen.add(key)
                errs.append(ln.strip())
    if not errs:
        return "\n".join(out.rstrip().splitlines()[-12:])
    head = errs[:limit]
    if len(errs) > limit:
        head.append(f"... 另有 {len(errs) - limit} 条同类错误")
    return "\n".join(head)


def _clean(s: str) -> str:
    """vsim 的控制台输出不保证编码 (中文会变 mojibake), 只保留可打印 ASCII + 通用字符。"""
    out = []
    for ch in s:
        o = ord(ch)
        if o < 128 and (ch.isprintable() or ch == " "):
            out.append(ch)
        elif o > 0x2E80:          # CJK 等: 说明编码本来就是对的, 保留
            out.append(ch)
        # 其余 (mojibake 字节 / 控制字符) 丢弃
    cleaned = "".join(out).strip()
    # 若清洗后几乎不剩东西, 给个占位说明
    return cleaned if len(cleaned) >= 3 else (s[:60].strip() + "  <编码乱码, 见 .fpga-cache/logs/>")


def _first_failure(out: str) -> str:
    """从 tb 输出里抓第一条有信息量的失败原因。"""
    for ln in out.splitlines():
        s = ln.strip().lstrip("#").strip()
        if re.search(r"RESULT : FAIL|FAIL:|timeout|illegal instruction", s, re.I):
            return s[:110]
    for ln in out.splitlines():
        s = ln.strip()
        if "ERROR!" in s or "Errors:" in s:
            return s[:110]
    return ""


def _indent(text: str, n: int = 6) -> str:
    pad = " " * n
    return "\n".join(pad + ln for ln in text.rstrip().splitlines()[-40:])


def _tail_interesting(out: str) -> str:
    """挑出输出里有信息量的部分, 而不是把 4000 行刷屏。"""
    keep = []
    for ln in out.splitlines():
        if re.search(r"PASS|FAIL|ERROR|Error|Total ticks|Iterations|CRC|crc|"
                     r"ALL TESTS|illegal|Mismatch|expected|timeout|TIMEOUT|"
                     r"cycles|fetch|retire|redirects|stalls|load-use|split-mem|"
                     r"muldiv|ctrl-flow|mispredict|cond branch|JAL|JALR|CPI|profile", ln):
            keep.append(ln)
    return "\n".join(keep[-70:]) if keep else "\n".join(out.splitlines()[-20:])


# ==========================================================================
# report: 三项指标 + 绝对吞吐
# ==========================================================================
def cmd_report(args) -> int:
    csv_path = abspath("results/coremark.csv")
    print("=" * 78)
    print("  三项指标 + 绝对吞吐  (赛题记三项: CoreMark/MHz, fmax, CoreMark/LUTs)")
    print("=" * 78)
    try:
        lines = [l for l in read_text(csv_path).splitlines() if l and not l.startswith("#")]
    except OSError:
        print(f"读不到 {csv_path}")
        return 1

    hdr = lines[0].split(",")
    rows = []
    for l in lines[1:]:
        parts = re.findall(r'[^,"]+|"[^"]*"', l)
        rows.append(dict(zip(hdr, parts)))

    def fnum(d, k):
        try:
            return float(str(d.get(k, "")).strip('"'))
        except ValueError:
            return None

    print(f"\n{'tag':22s} {'state':9s} {'CM/MHz':>9s} {'LUT':>6s} {'fmax':>6s} "
          f"{'CM/LUTs':>11s} {'绝对吞吐':>9s}")
    print("-" * 78)
    for d in rows:
        cm, lut, fmax = fnum(d, "coremark_per_mhz"), fnum(d, "lut"), fnum(d, "fmax_mhz")
        cmlut = cm / lut if (cm and lut) else None
        thr = cm * fmax if (cm and fmax) else None
        print(f"{d.get('tag',''):22s} {d.get('status',''):9s} "
              f"{(f'{cm:.4f}' if cm else '-'):>9s} {(f'{lut:.0f}' if lut else '-'):>6s} "
              f"{(f'{fmax:.1f}' if fmax else '-'):>6s} "
              f"{(f'{cmlut:.3e}' if cmlut else '-'):>11s} "
              f"{(f'{thr:.1f}' if thr else '-'):>9s}")

    kept = [d for d in rows if d.get("status") == "keep" and fnum(d, "coremark_per_mhz")]
    if len(kept) >= 2:
        base, cur = kept[0], kept[-1]
        print("\n  最新保留配置 vs 基线 (表内数据 = CSV 记录值):")
        for key, label, unit, fmt in [
            ("coremark_per_mhz", "CoreMark/MHz", "", "{:.4f}"),
            ("fmax_mhz", "fmax", " MHz", "{:.1f}"),
        ]:
            a, b = fnum(base, key), fnum(cur, key)
            if a and b:
                print(f"    {label:14s} {fmt.format(a)}{unit} -> {fmt.format(b)}{unit}"
                      f"   ({100*(b-a)/a:+.1f}%)")
        a = fnum(base, "coremark_per_mhz") / fnum(base, "lut")
        b = fnum(cur, "coremark_per_mhz") / fnum(cur, "lut")
        print(f"    {'CoreMark/LUTs':14s} {a:.3e} -> {b:.3e}   ({100*(b-a)/a:+.1f}%)")
        a = fnum(base, "coremark_per_mhz") * fnum(base, "fmax_mhz")
        b = fnum(cur, "coremark_per_mhz") * fnum(cur, "fmax_mhz")
        print(f"    {'绝对吞吐':14s} {a:.1f} -> {b:.1f}   ({100*(b-a)/a:+.1f}%)")
    print("\n  提示: 上表数字是 CSV 里当初记录的值 (那一次构建的实测)。"
          "\n        要看此刻的四项指标 (从最新仿真日志与归档报告实算), 用 metrics 子命令。")
    print("=" * 78)
    return 0


# ==========================================================================
# synth: 自动化"测量"半环 (Vivado 综合 -> 四项指标)
# ==========================================================================
LOCK_FILE = os.path.join(CACHE_DIR, "vivado.lock")
BUILD_TCL = "fpga/build.tcl"


class BuildLock:
    """全局构建锁: 保证同一时刻只有一个 Vivado 在跑。

    为什么必须串行化 (PITFALLS 四·构建工具链):
      两个 Vivado 实例重叠会让 IP 生成器初始化失败, 而且**谎报**
      `pkgIndex.tcl` 缺失 / `::ipgen_iptclns` 初始化失败 —— 报错指向完全无关的地方,
      极难定位。A(评分版) 与 C(测量) 并行推进时这条尤其致命。
    用 O_EXCL 原子创建 + 陈旧锁回收 (记 pid, 进程没了就抢)。
    """

    def __init__(self, timeout=1800):
        self.timeout = timeout

    def __enter__(self):
        os.makedirs(CACHE_DIR, exist_ok=True)
        t0 = time.time()
        announced = False
        while True:
            try:
                fd = os.open(LOCK_FILE, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                os.write(fd, str(os.getpid()).encode())
                os.close(fd)
                return self
            except FileExistsError:
                # 陈旧锁回收
                try:
                    with open(LOCK_FILE) as f:
                        pid = int(f.read().strip() or 0)
                except (OSError, ValueError):
                    pid = 0
                if pid and not _pid_alive(pid):
                    print(f"    (回收陈旧构建锁: pid {pid} 已不存在)")
                    try:
                        os.remove(LOCK_FILE)
                    except OSError:
                        pass
                    continue
                if time.time() - t0 > self.timeout:
                    raise TimeoutError(
                        f"等待 Vivado 构建锁超过 {self.timeout}s (持有者 pid={pid})")
                if not announced:
                    print(f"    (等待构建锁, 持有者 pid={pid} —— Vivado 必须串行)")
                    announced = True
                time.sleep(2)

    def __exit__(self, *exc):
        try:
            os.remove(LOCK_FILE)
        except OSError:
            pass
        return False


def _pid_alive(pid: int) -> bool:
    try:
        r = subprocess.run(["tasklist", "/FI", f"PID eq {pid}", "/NH"],
                           capture_output=True, text=True, errors="replace", timeout=30,
                           env=clean_env())
        return str(pid) in (r.stdout or "")
    except Exception:
        return True      # 判断不了就当作活着, 宁可等


def patch_build_prog(prog: str) -> str:
    """把 build.tcl 里的 `set PROG <x>` 改成指定程序, 返回原文本以便还原。"""
    path = abspath(BUILD_TCL)
    orig = read_text(path)
    new, n = re.subn(r"^set PROG \S+$", f"set PROG {prog}", orig, count=1, flags=re.M)
    if n != 1:
        raise RuntimeError(f"{BUILD_TCL}: 找不到 `set PROG <name>` 那一行")
    if new != orig:
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(new)
    return orig


def restore_build_prog(orig: str) -> None:
    with open(abspath(BUILD_TCL), "w", encoding="utf-8", newline="\n") as f:
        f.write(orig)


def parse_reports() -> dict:
    """从 Vivado 报告里抽 fmax 与资源。"""
    out = {"lut": None, "ff": None, "bram": None, "dsp": None, "wns": None, "fmax": None}

    util = abspath("fpga/util.rpt")
    if os.path.exists(util):
        u = read_text(util)

        def grab(label):
            m = re.search(re.escape(label) + r"\s*\|\s*(\d+)", u)
            return int(m.group(1)) if m else None

        out["lut"] = grab("Slice LUTs")
        out["ff"] = grab("Slice Registers")
        out["bram"] = grab("Block RAM Tile")
        out["dsp"] = grab("DSPs")

    tim = abspath("fpga/timing.rpt")
    if os.path.exists(tim):
        t = read_text(tim)
        # 只要 sys_clk 那一行的 WNS; 用表格里第一处出现
        m = re.search(r"^\s*sys_clk\s+(-?[\d.]+)", t, re.M)
        if m:
            wns = float(m.group(1))
            out["wns"] = wns
            # 约束周期 20ns (50 MHz) -> fmax = 1000/(20-wns)
            if wns < 20.0:
                out["fmax"] = 1000.0 / (20.0 - wns)
    return out


def latest_ticks(iters: int | None = None) -> tuple[int, int] | None:
    """取 CoreMark 的 (ticks, iters)。

    【优先用仿真日志的真值, 而不是 CSV 里的历史值】
    CSV 里的 ticks 是"当初那次"的数字; 修改 RTL 后它可能已经变了 (或不变量本身
    就该重测)。实测踩过: CSV 写 423,486, 而干净的仿真日志是 423,527 —— 两者
    CoreMark/MHz 差 0.01%, 看起来无所谓, 但"用旧值算新架的指标"是错的口径。

    所以: 有 tb_sw_coremark 日志就用日志里的 CoreMark ticks (它还同时给出 CRC,
    可顺带校验正确性); 没有才回退到 CSV。
    """
    p = parse_profile(read_text(os.path.join(LOG_DIR, "tb_sw_coremark.log"))) \
        if os.path.exists(os.path.join(LOG_DIR, "tb_sw_coremark.log")) else {}
    cm_ticks, it = p.get("cm_ticks"), p.get("iterations")
    if cm_ticks and it and (iters is None or it == iters):
        return cm_ticks, it

    try:
        lines = [l for l in read_text(abspath("results/coremark.csv")).splitlines()
                 if l and not l.startswith("#")]
    except OSError:
        return None
    hdr = lines[0].split(",")
    best = None
    for l in lines[1:]:
        parts = re.findall(r'[^,"]+|"[^"]*"', l)
        d = dict(zip(hdr, parts))
        tag = d.get("tag", "")
        if "HARDWARE" in tag:
            continue
        try:
            tk, it2 = int(d["ticks"]), int(d["iters"])
        except (KeyError, ValueError):
            continue
        if iters is not None and it2 != iters:
            continue
        best = (tk, it2)
    return best


def compute_metrics(res: dict, iters: int | None = None) -> dict:
    """四项指标: CoreMark/MHz, fmax, CoreMark/LUTs, 绝对吞吐。"""
    m = dict(res)
    cm = cmlut = thr = None
    tick = latest_ticks(iters)
    if tick:
        tk, it = tick
        cm = it * 1e6 / tk
        if res.get("lut"):
            cmlut = cm / res["lut"]
        if res.get("fmax"):
            thr = cm * res["fmax"]
    m.update({"cm_mhz": cm, "cm_lut": cmlut, "throughput": thr,
              "ticks": tick[0] if tick else None, "iters": tick[1] if tick else None})
    return m


def print_metrics(m: dict) -> None:
    print("\n  " + "-" * 66)
    print("  四项指标  (赛题记三项, 但必须同时看绝对吞吐)")
    print("  " + "-" * 66)
    rows = [
        ("CoreMark/MHz", m.get("cm_mhz"), "{:.4f}", m.get("ticks"),
         f"{m['iters']} iters, {m['ticks']:,} ticks" if m.get("ticks") else "无 CoreMark 数据"),
        ("fmax", m.get("fmax"), "{:.1f} MHz", m.get("wns"),
         f"WNS {m['wns']:.3f} ns @20ns 约束" if m.get("wns") is not None else ""),
        ("CoreMark/LUTs", m.get("cm_lut"), "{:.3e}", m.get("lut"),
         f"LUT {m.get('lut')} FF {m.get('ff')} BRAM {m.get('bram')} DSP {m.get('dsp')}"),
        ("绝对吞吐", m.get("throughput"), "{:.1f}", None, "CoreMark/MHz x fmax"),
    ]
    for label, val, fmt, _x, note in rows:
        shown = fmt.format(val) if val is not None else "n/a"
        print(f"    {label:16s} {shown:>14s}   {note}")
    print("  " + "-" * 66)


def append_csv(tag: str, m: dict) -> None:
    """把一行追加进 results/coremark.csv, 并保持列顺序与表头一致。"""
    path = abspath("results/coremark.csv")
    hdr_line = next(l for l in read_text(path).splitlines() if l.startswith("date,"))
    hdr = hdr_line.split(",")
    row = {
        "date": time.strftime("%Y-%m-%d"), "tag": tag,
        "iters": m.get("iters") or "", "ticks": m.get("ticks") or "",
        "coremark_per_mhz": f"{m['cm_mhz']:.4f}" if m.get("cm_mhz") else "",
        "lut": m.get("lut") or "", "ff": m.get("ff") or "",
        "bram": m.get("bram") or "", "dsp": m.get("dsp") or "",
        "fmax_mhz": f"{m['fmax']:.1f}" if m.get("fmax") else "",
        "status": "keep",
        # 调用方可以给更准确的 notes (例如 hw 是"上板实测"); 没给才用 synth 默认文案
        "notes": m.get("note") or f"fpga_workflow.py synth (PROG={m.get('prog','?')})",
    }
    cells = []
    for k in hdr:
        v = str(row.get(k, ""))
        cells.append(f'"{v}"' if ("," in v or '"' in v) else v)
    with open(path, "a", encoding="utf-8", newline="") as f:
        f.write(",".join(cells) + "\n")
    print(f"\n  -> 追加到 results/coremark.csv: {tag}")


def cmd_synth(args) -> int:
    prog = args.prog
    print("=" * 74)
    print("  Vivado 综合 -> 四项指标   (评分版, 非工程模式)")
    print(f"  程序镜像 PROG={prog}   part=xc7a100tfgg484-2")
    print("=" * 74)

    imem = abspath(f"sim/prog/{prog}.hex")
    dmem = abspath(f"sim/prog/{prog}.dmem.hex")
    for label, p in (("imem", imem), ("dmem", dmem)):
        if not os.path.exists(p):
            print(f"  [BLOCK] 缺 {label} 镜像 {p}")
            print("          先构建: python tools/build_sw.py sw/coremark/*.c -I sw/coremark \\")
            print("                    -D ITERATIONS=1200 --march=rv32im -o sim/prog/cm_hw.hex")
            return 1

    # 缓存键 = 所有综合输入的内容哈希 + PROG
    h = hashlib.sha256()
    for f in canonical_rtl() + ["fpga/top_a100t.sv", "fpga/mmio_subsys.sv",
                                "fpga/daVinciPro.xdc", "fpga/build.tcl"]:
        p = abspath(f)
        h.update(f.encode())
        h.update(sha256_file(p).encode() if os.path.exists(p) else b"MISSING")
    for p in (imem, dmem):
        h.update(sha256_file(p).encode())
    h.update(prog.encode())
    # 指纹必须覆盖**所有影响网表的开关**, 否则改开关会命中旧缓存、拿到旧数字。
    # 注意与 build.tcl 里的默认保持一致 (默认三宏全关 + RAS 关)。
    h.update(b"regread" if args.imem_reg_read else b"combread")
    h.update(b"loadreg" if args.load_reg else b"loadcomb")
    h.update(b"gshare" if args.gshare else b"smith")
    h.update(b"ras" if args.ras else b"noras")
    fp = h.hexdigest()[:32]

    cache = os.path.join(CACHE_DIR, "synth-cache.json")
    try:
        cstate = json.loads(read_text(cache))
    except Exception:
        cstate = {}
    if not args.force and cstate.get("fingerprint") == fp and os.path.exists(abspath("fpga/cpu_a100t.bit")):
        print(f"  [SKIP] RTL 与镜像都未变, 复用上次构建结果 "
              f"({time.strftime('%m-%d %H:%M', time.localtime(cstate.get('when', 0)))})")
        res = parse_reports()
        res["prog"] = prog
        print_metrics(compute_metrics(res))
        if args.record:
            append_csv(args.tag or f"synth-{prog}", compute_metrics(res))
        return 0

    if not os.path.exists(VIVADO_BAT):
        print(f"  [BLOCK] 找不到 {VIVADO_BAT}")
        return 1

    orig = None
    with BuildLock(timeout=args.lock_timeout):
        try:
            orig = patch_build_prog(prog)
            print(f"  [1/2] patched {BUILD_TCL}: PROG={prog}")
            log = os.path.join(CACHE_DIR, "synth.log")
            os.makedirs(CACHE_DIR, exist_ok=True)
            t0 = time.time()
            # 走 .bat: 它负责 call settings64.bat (Vivado 未加入 PATH)。
            # 架构宏通过环境变量传给 build.tcl (Tcl 读 $::env)。
            # 默认**一个都不设** = 三宏全关 = 上板验证过的配置。
            benv = clean_env()
            if args.imem_reg_read:
                # build.tcl 检测到它时**直接报错退出** —— 该配置需重排取指流水,
                # 当前会让 pc_plus4/跳转目标整体偏移。见 results/p4-macro-failure.md
                benv["IMEM_REG_READ"] = "1"
            if args.load_reg:
                benv["LOAD_REG"] = "1"
            if args.gshare:
                benv["BTB_GSHARE"] = "1"
            if args.ras:
                benv["RAS_EN"] = "1"
            rc, out, dt = run(["cmd", "/c", abspath("fpga/build.bat")],
                              cwd=abspath("fpga"), timeout=args.timeout, env=benv)
            with open(log, "w", encoding="utf-8") as f:
                f.write(out)
            ok = "BUILD_OK" in out
            print(f"  [2/2] vivado rc={rc} {'BUILD_OK' if ok else 'FAILED'}  {dt:.0f}s")
            if not ok:
                why = [l for l in out.splitlines()
                       if "BUILD_ERROR" in l or "ERROR:" in l or "BUILD_HINT" in l]
                for l in why[:12]:
                    print("        " + l.strip())
                print(f"       完整日志: {log}")
                return 1
        finally:
            if orig is not None:
                restore_build_prog(orig)

    res = parse_reports()
    res["prog"] = prog
    if not res.get("lut"):
        print("  [warn] util.rpt 里没解析到 LUT, 资源数字可能不准")
    print_metrics(compute_metrics(res))

    # 记录本次构建所用的镜像内容哈希。
    # 为什么: check 的 bitstream 新鲜度原来只能比 mtime —— 而"重建了逐字节相同的
    # 镜像"会让 mtime 变新从而误报 stale。有了哈希就能区分
    # "镜像真的变了" 与 "文件被重写但内容一样"。
    try:
        sstate = os.path.join(CACHE_DIR, "synth-cache.json")
        try:
            sc = json.loads(read_text(sstate))
        except Exception:
            sc = {}
        sc.setdefault("image_hash", {})[prog] = {
            "imem": sha256_file(imem), "dmem": sha256_file(dmem)
        }
        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(sstate, "w", encoding="utf-8") as f:
            json.dump(sc, f, indent=1, ensure_ascii=False)
    except OSError as e:
        print(f"  [warn] 记录镜像哈希失败: {e}")

    # 归档本次报告: timing.rpt/util.rpt 每次构建都被覆盖, 不留档就没法回查
    # (本项目就出现过"旧报告被覆盖后无法复核历史数字"的情况)
    try:
        stamp = time.strftime("%Y%m%d-%H%M%S")
        arch = os.path.join(CACHE_DIR, "reports", f"{stamp}-{prog}")
        os.makedirs(arch, exist_ok=True)
        for n in ("timing.rpt", "util.rpt"):
            s = abspath("fpga/" + n)
            if os.path.exists(s):
                shutil.copy2(s, os.path.join(arch, n))
        with open(os.path.join(arch, "metrics.json"), "w", encoding="utf-8") as f:
            json.dump(compute_metrics(res), f, indent=1, ensure_ascii=False)
        print(f"  报告已归档: {posix(os.path.relpath(arch, REPO))}")
    except OSError as e:
        print(f"  [warn] 报告归档失败: {e}")

    with open(cache, "w", encoding="utf-8") as f:
        json.dump({"fingerprint": fp, "when": time.time(), "prog": prog}, f, indent=1)

    if args.record:
        append_csv(args.tag or f"synth-{prog}", compute_metrics(res))
    return 0


# ==========================================================================
# metrics: 四项指标 + keep/reject 判定 (把赛题纪律编码进来)
# ==========================================================================
def read_csv_rows() -> list[dict]:
    path = abspath("results/coremark.csv")
    lines = [l for l in read_text(path).splitlines() if l and not l.startswith("#")]
    hdr = [h.strip() for h in lines[0].split(",")]
    rows = []
    for l in lines[1:]:
        parts = [p.strip() for p in re.findall(r'[^,"]+|"[^"]*"', l)]
        d = dict(zip(hdr, parts))
        d["_raw"] = l
        rows.append(d)
    return rows


def _f(row: dict, key: str):
    try:
        return float(str(row.get(key, "")).strip('"'))
    except ValueError:
        return None


def metric_set(row: dict) -> dict:
    """由一行 CSV 推出四项指标 (派生量现算, 避免依赖是否记录过)。"""
    cm = _f(row, "coremark_per_mhz")
    lut = _f(row, "lut")
    fmax = _f(row, "fmax_mhz")
    return {
        "coremark_per_mhz": cm,
        "fmax_mhz": fmax,
        "coremark_per_lut": (cm / lut) if (cm and lut) else None,
        "absolute": (cm * fmax) if (cm and fmax) else None,
    }


def find_row(tag: str) -> dict | None:
    for r in read_csv_rows():
        if r.get("tag") == tag:
            return r
    return None


def fmt_metric(k: str, v) -> str:
    if v is None:
        return "n/a"
    if k == "fmax_mhz":
        return f"{v:.1f} MHz"
    if k == "coremark_per_lut":
        return f"{v:.3e}"
    if k == "absolute":
        return f"{v:.1f}"
    return f"{v:.4f}"


def verdict(now: dict, prev: dict) -> tuple[str, list[str]]:
    """赢 2 输 1 才留 —— 阈值按 HANDOFF-WORKFLOW.md 第 3.1 节。

    0.5% 不是随手写的: 仿真噪声 + 工具重排会带来约 1% 抖动, 低于它不该算赢。
    绝对吞吐单独看: 它是"每秒跑多少次迭代", 是三项指标互相矛盾时的最终裁判。
    """
    notes, win, lose = [], 0, 0
    for k in ("coremark_per_mhz", "fmax_mhz", "coremark_per_lut"):
        a, b = prev.get(k), now.get(k)
        if not a or not b:
            continue
        if b > a * 1.005:
            win += 1
            notes.append(f"  WIN  {k:18s} {fmt_metric(k, a)} -> {fmt_metric(k, b)}  (+{100*(b-a)/a:.1f}%)")
        elif b < a * 0.995:
            lose += 1
            notes.append(f"  LOSE {k:18s} {fmt_metric(k, a)} -> {fmt_metric(k, b)}  ({100*(b-a)/a:+.1f}%)")
        else:
            notes.append(f"  ---- {k:18s} {fmt_metric(k, a)} -> {fmt_metric(k, b)}  (~持平)")
    if win > lose:
        v = "KEEP"
    elif lose > win:
        v = "REJECT"
    else:
        v = "TIE(看赛题取向)"
    a, b = prev.get("absolute"), now.get("absolute")
    if a and b:
        notes.append(f"  ABS  {'absolute':18s} {fmt_metric('absolute', a)} -> "
                     f"{fmt_metric('absolute', b)}  ({100*(b-a)/a:+.1f}%)")
        if b < a * 0.98:
            notes.append("  [WARN] 绝对吞吐下降 >2% —— 即使赢两项也要慎重")
    return v, notes


def cmd_metrics(args) -> int:
    rows = read_csv_rows()
    # 当前值: 优先命令行直传, 否则取最近一次综合的归档报告
    res = parse_reports()
    if args.ticks:
        it = args.iters or 1
        res["cm_mhz"] = it * 1e6 / args.ticks
    else:
        res = compute_metrics(res)
    now = {
        "coremark_per_mhz": res.get("cm_mhz"),
        "fmax_mhz": res.get("fmax"),
        "coremark_per_lut": res.get("cm_lut"),
        "absolute": res.get("throughput"),
    }
    print("=" * 74)
    print("  当前四项指标")
    print("=" * 74)
    for k, v in now.items():
        print(f"    {k:20s} {fmt_metric(k, v)}")
    if not any(now.values()):
        print("\n  [warn] 四项全空 —— 先跑一次 synth, 或用 --ticks 指定 ticks")
        return 1

    if not args.vs:
        print("\n  (加 --vs <tag> 可与历史某行对比并给出 keep/reject 判定)")
        return 0

    prev_row = find_row(args.vs)
    if not prev_row:
        tags = [r.get("tag") for r in rows][-8:]
        print(f"\n  [FAIL] coremark.csv 里没有 tag = {args.vs}")
        print(f"         最近的 tag: {', '.join(str(t) for t in tags)}")
        return 1

    prev = metric_set(prev_row)
    print(f"\n  对比基线: {args.vs}  ({prev_row.get('date','')})")
    print("  " + "-" * 70)
    v, notes = verdict(now, prev)
    for n in notes:
        print(n)
    print("  " + "-" * 70)
    print(f"  判定: {v}")
    print("=" * 74)
    print("\n  纪律提醒 (HANDOFF-WORKFLOW.md §1.2):")
    print("    · 一次只改一处, 否则归因不了")
    print("    · 结果与上次完全一致 -> 先怀疑镜像没重建, 别当成'改动无效'")
    print("    · 被否决的方案要记 rejected + 原因, 否则下一轮会重复试")
    return 0


# ==========================================================================
# profile: 剖析停顿构成 (优化前先测量)
# ==========================================================================
def parse_profile(out: str) -> dict:
    """从 tb_sw 的 profile 段落抽结构化数据。

    【分母要用 tb 的 cycles, 不能用 CoreMark 的 Total ticks】
    两者不同: CoreMark 的 ticks 只统计它自己的计时区间, 而 tb 的 cycles 从复位
    开始算, 多出启动/收尾的几万拍。算"某项占多少周期"必须用 tb cycles, 否则
    占比会被系统性低估。

    【ModelSim 会给每行加 "# " 前缀】所以先把行首的 '# ' 去掉再匹配 ——
    否则所有 ^ 锚定的正则都匹配不上 (踩过: 只有不带 ^ 的 mispredict/cond 匹配到了)。
    """
    # 去掉 ModelSim 的行首 "# " 注释前缀
    out = re.sub(r"^#\s?", "", out, flags=re.M)
    p: dict = {}

    def num(pat, key, grp=1):
        m = re.search(pat, out, re.M)
        if m:
            try:
                p[key] = int(m.group(grp))
            except ValueError:
                pass

    # 注意: 第一个 "cycles = N" 出现在 tb 启动日志里 ([tb_sw] reset released 之后
    # 也有一行), 所以用带标题的 "--- profile ---" 之后那一段更稳。
    seg = out.split("--- profile ---")[-1] if "--- profile ---" in out else out
    num(r"^\s*cycles\s*=\s*(\d+)", "ticks")
    num(r"^\s*fetch\s*=\s*(\d+)", "fetch")
    num(r"^\s*retire\(wb\)\s*=\s*(\d+)", "retire")
    num(r"^\s*redirects\s*=\s*(\d+)", "redirect_total")
    num(r"^\s*stalls\s*=\s*(\d+)", "stall_total")
    num(r"^\s*load-use\s*=\s*(\d+)", "stall_load_use")
    num(r"^\s*split-mem\s*=\s*(\d+)", "stall_split_mem")
    num(r"muldiv busy=\s*(\d+)", "stall_muldiv")
    num(r"ctrl-flow\s*=\s*(\d+)", "ctrl_flow")
    num(r"mispredict\s*=\s*(\d+)", "mispredict")
    num(r"cond branch total\s*=\s*(\d+)", "cond_total")
    num(r"^\s*JAL\s*=\s*(\d+)", "jal")
    num(r"^\s*JALR\s*=\s*(\d+)", "jalr")
    num(r"^\s*Total ticks\s*:\s*(\d+)", "cm_ticks")
    num(r"^\s*Iterations\s*:\s*(\d+)", "iterations")

    # tb 的 cycles 必须从 profile 段取 (CoreMark 的 Total ticks 只覆盖它自己的
    # 计时区间, 少了启动/收尾的几万拍, 当分母会低估占比)
    m = re.search(r"cycles\s*=\s*(\d+)", seg)
    if m:
        p["ticks"] = int(m.group(1))

    if p.get("retire"):
        p["cpi"] = round(p["ticks"] / p["retire"], 3)
    if p.get("ctrl_flow"):
        p["predict_accuracy"] = round(1 - p["mispredict"] / p["ctrl_flow"], 4)
    cyc = p.get("ticks") or 0
    if cyc:
        # 每项占周期总数的百分比 —— "取占比最大的那一项"是选靶子的规则。
        # redirect 每次损失 2 拍, 所以乘 2。
        p["share_pct"] = {
            "load_use":  round(100 * p.get("stall_load_use", 0) / cyc, 1),
            "muldiv":    round(100 * p.get("stall_muldiv", 0) / cyc, 1),
            "split_mem": round(100 * p.get("stall_split_mem", 0) / cyc, 1),
            "redirect":  round(100 * p.get("redirect_total", 0) * 2 / cyc, 1),
        }
        # ---- 把 load-use 停顿从 1 拍加到 2 拍的**时间代价** ----
        # 停顿次数不变, 每次多 1 拍 -> 周期数从 cyc 变成 cyc + lu。
        # 时间涨幅 = (cyc + lu)/cyc - 1 = lu/cyc ... 但这里报的是
        # lu/(cyc+lu), 即"新总时间里有百分之多少是新加的" —— 与 share_pct
        # 同一口径 (占**新**总数的比例), 便于和 fmax 涨幅直接对比:
        #   需要 fmax 涨幅 > 这个数, 这笔交易才不亏。
        lu = p.get("stall_load_use", 0)
        if lu:
            p["cost_if_load_use_2cyc_pct"] = round(100 * lu / (cyc + lu), 2)
    return p


def cmd_profile(args) -> int:
    prog = args.prog
    print("=" * 74)
    print("  剖析: 周期花在哪 (优化前先测量, 不要猜)")
    print("=" * 74)
    imem = abspath(f"sim/prog/{prog}.hex")
    dmem = abspath(f"sim/prog/{prog}.dmem.hex")
    for label, p in (("imem", imem), ("dmem", dmem)):
        if not os.path.exists(p):
            print(f"  [BLOCK] 缺 {label} 镜像 {p}")
            return 1

    files = canonical_rtl()
    rc, out, workdir = compile_sim(files, "sim/tb_sw.sv")
    if rc != 0:
        print("  [FAIL] 编译失败")
        print(_indent(_vlog_errors(out)))
        return 1

    cmd = [os.path.join(MSIM, "vsim.exe"), "-c", "-do", "run -all; quit -f", "work.tb_sw",
           "+imem=" + imem, "+dmem=" + dmem, f"+max_cycles={args.max_cycles}"]
    rc, out, _ = run(cmd, cwd=workdir, timeout=args.timeout)
    if "RESULT : PASS" not in out:
        print("  [FAIL] 仿真未通过 (没有 RESULT : PASS), 剖析数据不可信")
        print(_indent(_tail_interesting(out)))
        return 1

    p = parse_profile(out)
    print("\n  周期构成 (占比最大的就是下一轮的靶子):")
    print("  " + "-" * 62)
    for k, v in sorted(p.get("share_pct", {}).items(), key=lambda kv: -kv[1]):
        bar = "#" * int(round(v))
        print(f"    {k:12s} {v:5.1f}%  {bar}")
    print("  " + "-" * 62)
    for k in ("ticks", "retire", "cpi", "predict_accuracy", "mispredict",
              "stall_load_use", "stall_muldiv", "stall_split_mem",
              "redirect_total", "cond_total", "jal", "jalr"):
        if k in p:
            print(f"    {k:18s} {p[k]}")
    if args.json:
        os.makedirs(os.path.dirname(abspath(args.json)), exist_ok=True)
        with open(abspath(args.json), "w", encoding="utf-8") as f:
            json.dump(p, f, indent=1, ensure_ascii=False)
        print(f"\n  -> {args.json}")
    print("=" * 74)
    return 0


# ==========================================================================
# hw: 解析上板 ILA 读回结果 (results/ila_done.csv)
# ==========================================================================
def cmd_hw(args) -> int:
    """解析 ILA over JTAG 读回的跑分结果。

    判据来自 HANDOFF-HW-LOOP.md: ila_ctrl 的位定义与 score_result 的打包方式。
    这是本板**唯一**能拿到上板结论的通道 (串口无 COM 口)。
    """
    path = abspath(args.csv)
    if not os.path.exists(path):
        print(f"  [BLOCK] 找不到 {args.csv}")
        print("          先跑: cmd /c fpga\\ila_cap_done.bat")
        return 1
    lines = [l for l in read_text(path).splitlines() if l.strip()]
    hdr = [h.strip().strip('"') for h in lines[0].split(",")]

    def col(name):
        for i, h in enumerate(hdr):
            if name in h:
                return i
        return None

    ic, ir = col("ila_ctrl"), col("score_result")
    if ic is None or ir is None:
        print(f"  [FAIL] CSV 里找不到 ila_ctrl / score_result 列。实际列: {hdr}")
        return 1

    def px(s):
        return int(s.strip().strip('"').replace("0x", ""), 16)

    # 抓到达 done=1 的那一拍 (程序跑完的状态)
    hit = None
    for ln in lines[1:]:
        c = ln.split(",")
        if len(c) <= max(ic, ir):
            continue
        ctrl, res = px(c[ic]), px(c[ir])
        if (ctrl >> 6) & 1:
            hit = (ctrl, res)
            break
    if hit is None:
        print("  [FAIL] 没有采到 done=1 —— 程序没跑完 (检查 ITERATIONS 与 after 等待时间)")
        c = lines[-1].split(",")
        print(f"         最后一拍: ila_ctrl=0x{px(c[ic]):02x} score_result=0x{px(c[ir]):08X}")
        return 1

    ctrl, res = hit
    done, mark = (ctrl >> 6) & 1, (ctrl >> 5) & 1
    illegal, p, f = (ctrl >> 2) & 1, (ctrl >> 1) & 1, ctrl & 1
    crc, tick = (res >> 31) & 1, res & 0x7FFFFFFF
    iters = args.iterations
    cmmhz = iters * 1e6 / tick if tick else 0
    secs = tick / args.clk_hz

    print("=" * 74)
    print("  上板读回结果 (ILA over JTAG)")
    print("=" * 74)
    print(f"  ila_ctrl     = 0x{ctrl:02X}  -> done={done} pass={p} fail={f} illegal={illegal}")
    print(f"  score_result = 0x{res:08X}")
    print(f"    bit31 = {crc}  -> CRC 判定 {'全部匹配官方参考值' if crc else '不匹配 !!'}")
    print(f"    tick  = {tick:,}")
    print(f"    iterations = {iters}")
    print(f"    CoreMark/MHz = {cmmhz:.4f}")
    print(f"    时长 = {secs:.2f} s @{args.clk_hz/1e6:.0f}MHz"
          f"  (赛题要求 >= 10 s: {'满足' if secs >= 10 else '不满足 !!'})")
    if args.expect_tick:
        print(f"    对照预期 {args.expect_tick:,}: 偏差 "
              f"{abs(tick-args.expect_tick)/args.expect_tick*100:.3f}%")
    ok = done and p and not f and not illegal and crc
    print(f"\n  => 上板验证 {'PASS' if ok else 'FAIL'}")

    if args.record:
        res_m = parse_reports()
        m = {"cm_mhz": cmmhz, "fmax": res_m.get("fmax"), "lut": res_m.get("lut"),
             "ff": res_m.get("ff"), "bram": res_m.get("bram"), "dsp": res_m.get("dsp"),
             "cm_lut": (cmmhz / res_m["lut"]) if res_m.get("lut") else None,
             "throughput": (cmmhz * res_m["fmax"]) if res_m.get("fmax") else None,
             "iters": iters, "ticks": tick,
             "note": ("上板实测 (ILA over JTAG): %d 迭代, %.2fs, CRC 判定=%d; "
                      "资源取自最近一次 synth 归档" % (iters, secs, crc))}
        append_csv(args.tag or "HARDWARE-RERUN", m)
    print("=" * 74)
    return 0 if ok else 1


# ==========================================================================
# doctor
# ==========================================================================
def cmd_doctor(args) -> int:
    print("=" * 74)
    print("  环境自检")
    print("=" * 74)
    checks = [
        ("ModelSim vsim", MSIM + "/vsim.exe"),
        ("ModelSim vlog", MSIM + "/vlog.exe"),
        ("ModelSim license", MSIM_LIC),
        ("RISC-V GCC", GCC),
        ("Vivado", VIVADO_BAT),
        ("Python", PYTHON),
    ]
    bad = 0
    for label, p in checks:
        ok = os.path.exists(p)
        bad += 0 if ok else 1
        print(f"  {'OK  ' if ok else 'FAIL'} {label:20s} {p}")

    print(f"\n  会话环境: process.env 有 {len([v for v in os.environ.values() if v])} 个非空变量")
    print(f"  PROCESSOR_ARCHITECTURE = {os.environ.get('PROCESSOR_ARCHITECTURE', '(缺, 由 clean_env 补)')}")
    print(f"  LM_LICENSE_FILE        = {os.environ.get('LM_LICENSE_FILE', '(缺, 由 clean_env 补)')}")
    print(f"  tempdir                = {tempfile.gettempdir()}")
    if not os.path.isabs(tempfile.gettempdir()):
        print("  [warn] tempdir 是相对路径 -> 临时文件会落进工作区 (SKILL 第 2.4 条)")
    print(f"  RISC-V GCC 版本        = {gcc_version()}")
    print(f"  仓库根                 = {REPO}")
    print("=" * 74)
    return 1 if bad else 0


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="fpga_workflow.py",
        description="RISC-V CPU 工程统一工作流 (校验/回归/报告)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("doctor", help="环境自检")
    p.set_defaults(func=cmd_doctor)

    p = sub.add_parser("check", help="R1 漂移检测 (文件清单/地址/编码/新鲜度)")
    p.set_defaults(func=cmd_check)

    p = sub.add_parser("verify", help="ModelSim 增量回归")
    p.add_argument("--only", nargs="*", help="只跑指定测试名")
    p.add_argument("--force", action="store_true", help="忽略缓存全量重跑")
    p.add_argument("--imem_reg_read", action="store_true",
                   help="取指存储器用寄存读 (IMEM_REG_READ); 默认组合读")
    p.add_argument("--load_reg", action="store_true",
                   help="load 结果由 MEM/WB 寄存器给出 (LOAD_RESULT_REG); 默认组合")
    p.add_argument("--gshare", action="store_true",
                   help="方向预测器用 gshare (BTB_GSHARE); 默认纯局部 Smith")
    p.add_argument("--ras", action="store_true",
                   help="启用返回地址栈 (RAS_EN); 默认关闭 (实测综合指标净亏)")
    p.add_argument("-v", "--verbose", action="store_true", help="通过时也打印摘要")
    p.set_defaults(func=cmd_verify)

    p = sub.add_parser("report", help="三项指标 + 绝对吞吐")
    p.set_defaults(func=cmd_report)

    p = sub.add_parser("metrics", help="四项指标 + keep/reject 判定 (含绝对吞吐裁判)")
    p.add_argument("--vs", metavar="TAG", help="与 coremark.csv 里某个 tag 对比")
    p.add_argument("--ticks", type=int, help="直接给 ticks (否则用最近归档报告 + CSV)")
    p.add_argument("--iters", type=int, default=1, help="配合 --ticks 的迭代次数")
    p.set_defaults(func=cmd_metrics)

    p = sub.add_parser("profile", help="剖析停顿构成 (优化前先测量)")
    p.add_argument("--prog", default="cm_rv32im", help="程序基名 (默认 cm_rv32im)")
    p.add_argument("--json", help="结果写到这个 JSON 路径")
    p.add_argument("--max-cycles", type=int, default=5000000)
    p.add_argument("--timeout", type=int, default=1200)
    p.set_defaults(func=cmd_profile)

    p = sub.add_parser("hw", help="解析上板 ILA 读回结果 (results/ila_done.csv)")
    p.add_argument("--csv", default="results/ila_done.csv", help="ILA 抓取的 CSV")
    p.add_argument("--iterations", type=int, default=1200, help="镜像里的 ITERATIONS")
    p.add_argument("--clk-hz", type=float, default=50e6, help="板载时钟频率 (默认 50MHz)")
    p.add_argument("--expect-tick", type=int, help="预期 tick, 用于算偏差")
    p.add_argument("--tag", help="记录进 coremark.csv 的标签")
    p.add_argument("--record", action="store_true", help="追加一行到 results/coremark.csv")
    p.set_defaults(func=cmd_hw)

    p = sub.add_parser("synth", help="Vivado 综合 -> 四项指标 (自动串行化 + 缓存)")
    p.add_argument("--prog", default="cm_hw",
                   help="要综合进 imem/dmem 的程序基名 (默认 cm_hw = 跑分版)")
    p.add_argument("--tag", help="记录进 results/coremark.csv 用的标签")
    p.add_argument("--record", action="store_true", help="追加一行到 results/coremark.csv")
    p.add_argument("--force", action="store_true", help="忽略缓存强制重建")
    # 【注意默认值】三个架构宏默认**全关** —— 与上板验证过的配置一致。
    # IMEM_REG_READ 目前不可用 (需重排取指流水, build.tcl 会直接拦住)。
    p.add_argument("--imem-reg-read", action="store_true",
                   help="取指存储器用寄存读 (IMEM_REG_READ); 当前不可用, 见 p4-macro-failure.md")
    p.add_argument("--load-reg", action="store_true",
                   help="load 结果由 MEM/WB 寄存器给出 (LOAD_RESULT_REG); 默认组合")
    p.add_argument("--gshare", action="store_true",
                   help="方向预测器用 gshare (BTB_GSHARE); 默认纯 Smith")
    p.add_argument("--ras", action="store_true",
                   help="启用返回地址栈 (RAS_EN); 默认关闭 (实测综合指标净亏)")
    p.add_argument("--timeout", type=int, default=3600, help="Vivado 超时秒数")
    p.add_argument("--lock-timeout", type=int, default=1800, help="等待构建锁的秒数")
    p.set_defaults(func=cmd_synth)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
