#!/usr/bin/env python3
"""build_sw.py - RISC-V rv32i bare-metal build: compile + link + imem hex

Usage:
    python tools/build_sw.py sw/hello.c sw/portme.c -o sim/prog/hello.hex
    python tools/build_sw.py sw/coremark/*.c sw/coremark_portme.c -I sw/coremark -o sim/prog/coremark.hex

Notes:
  - sw/crt0.S and sw/libc_min.c are ALWAYS linked in (mandatory startup + minimal libc).
    Forgetting crt0.S makes --gc-sections drop the whole program (silent 0-byte image).
  - -nostdlib avoids newlib bloat, but -lgcc is required: RV32I has no HW multiply/divide,
    so gcc emits __mulsi3/__udivsi3/... calls.
"""

import argparse, glob, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DEFAULT_GCC_DIR = r'D:\software\tools\riscv-none-elf\xpack-riscv-none-elf-gcc-15.2.0-1\bin'
DEFAULT_LD = os.path.join(REPO, 'sw', 'link.ld')
ALWAYS = [os.path.join(REPO, 'sw', 'crt0.S'), os.path.join(REPO, 'sw', 'libc_min.c')]


def find_tool(name, gcc_dir):
    for d in [gcc_dir] + os.environ.get('PATH', '').split(os.pathsep):
        if not d:
            continue
        for suffix in ('.exe', ''):
            p = os.path.join(d, name + suffix)
            if os.path.exists(p):
                return p
    return name


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('sources', nargs='*')
    ap.add_argument('-o', '--output', required=True)
    ap.add_argument('-I', '--include', action='append', default=[])
    ap.add_argument('-D', '--define', action='append', default=[])
    ap.add_argument('--ld', default=DEFAULT_LD)
    ap.add_argument('--gcc-dir', default=DEFAULT_GCC_DIR)
    ap.add_argument('-O', '--opt', default='-Os')
    ap.add_argument('--march', default='rv32i',
                    help='ISA 字符串, 如 rv32i / rv32im。注意: 这个才是真正生效的, '
                         '-D FLAGS_STR 只影响 CoreMark 打印出来的字符串')
    ap.add_argument('--no-gc', action='store_true', help='disable --gc-sections')
    args = ap.parse_args()

    gcc = find_tool('riscv-none-elf-gcc', args.gcc_dir)
    objcopy = find_tool('riscv-none-elf-objcopy', args.gcc_dir)
    gcc_dir = os.path.dirname(gcc)

    elf = os.path.splitext(args.output)[0] + '.elf'
    mapf = os.path.splitext(args.output)[0] + '.map'

    srcs = list(ALWAYS)
    for s in args.sources:
        hits = glob.glob(s)
        srcs.extend(hits if hits else [s])
    for s in srcs:
        if not os.path.exists(s):
            print('MISSING SOURCE: %s' % s, file=sys.stderr)
            return 1

    cmd = [gcc, '-march=' + args.march, '-mabi=ilp32', args.opt,
           '-ffreestanding', '-fno-builtin', '-fno-strict-aliasing',
           '-nostdlib', '-nostartfiles',
           '-Wl,-Map=' + mapf,
           '-Wl,--no-warn-rwx-segments',
           '-T', args.ld, '-o', elf]
    if not args.no_gc:
        cmd += ['-Wl,--gc-sections', '-ffunction-sections', '-fdata-sections']
    cmd += ['-I' + i for i in args.include]
    cmd += ['-D' + d for d in args.define]
    cmd += srcs + ['-lgcc']

    print('[cc] %d sources -> %s' % (len(srcs), os.path.basename(elf)))
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.stdout.strip():
        print(r.stdout.strip())
    if r.returncode != 0:
        print(r.stderr, file=sys.stderr)
        print('BUILD FAILED', file=sys.stderr)
        return 1
    if r.stderr.strip():
        print(r.stderr.strip())

    r2 = subprocess.run([sys.executable, os.path.join(HERE, 'elf2hex.py'),
                         elf, '-o', args.output, '--objcopy', objcopy],
                        capture_output=True, text=True)
    print(r2.stdout.strip())
    if r2.returncode != 0:
        print(r2.stderr, file=sys.stderr)
        return r2.returncode

    size = find_tool('riscv-none-elf-size', gcc_dir)
    rs = subprocess.run([size, '-A', elf], capture_output=True, text=True)
    if rs.returncode == 0:
        for line in rs.stdout.splitlines():
            if line.strip() and not line.startswith('.'):
                print('    ' + line.strip())
            elif line.startswith('.'):
                parts = line.split()
                if len(parts) >= 2:
                    print('    %-14s %6s' % (parts[0], parts[1]))
    print('[OK] %s' % args.output)
    return 0


if __name__ == '__main__':
    sys.exit(main())
