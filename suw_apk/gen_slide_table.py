# -*- coding: utf-8 -*-
"""gen_slide_table.py — 把"正对照求 slide"需要的常量从 kallsyms 里抽出来, 生成 Java 源
(suw_apk/src/com/suw/manager/SlideTable.java), 这样 APK 能自己解 slide 而不必先回主机跑 python。

判据与 analysis/slide_pc.py 逐字对齐: 同一批 CTRL 函数、同样"宽度截到 0x700"、
同样 TEXT/ETEXT/STEP=2MB。两边不一致时以 slide_pc.py 为准(它是真机验证过的那份)。
"""
import io, os, re, sys

for _n in ('stdout', 'stderr'):
    try:
        getattr(sys, _n).reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass

BASE = r'G:\项目\Windows管理\usb\临时root'
KS = os.path.join(BASE, 'analysis', 'kallsyms_g2a88cd145def.txt')
OUT = os.path.join(BASE, 'suw_apk', 'src', 'com', 'suw', 'manager', 'SlideTable.java')
TEXT = 0xffffffc010080000
ETEXT = 0xffffffc0115a0000
STEP = 0x200000
CTRL = ['el0_svc', 'el0_svc_common', '__arm64_sys_getpid', '__arm64_sys_getppid',
        '__arm64_sys_newuname', '__arm64_sys_newfstat', 'vfs_statx', 'link_path_walk',
        '__arm64_sys_getdents64', 'user_path_at']

syms = []
for line in io.open(KS, encoding='utf-8', errors='replace'):
    p = line.split()
    if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
        syms.append((int(p[0], 16), ' '.join(p[2:])))
syms.sort()

win, missing = [], []
for nm in CTRL:
    hit = None
    for i, (a, n) in enumerate(syms):
        if n == nm and i + 1 < len(syms):
            hit = (a, min(syms[i + 1][0] - a, 0x700), nm)
            break
    if hit:
        win.append(hit)
    else:
        missing.append(nm)     # 与 slide_pc.py 一致: 找不到的**跳过**(它在本构建被内联掉了)
if missing:
    print('跳过 kallsyms 里没有的: %s' % ', '.join(missing))
if len(win) < 6:
    print('!! 窗口只剩 %d 个 ⇒ 判别力不够, 停' % len(win))
    sys.exit(2)

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with io.open(OUT, 'w', encoding='utf-8', newline='\n') as f:
    f.write('// 由 suw_apk/gen_slide_table.py 自动生成 —— 手改会被覆盖。\n')
    f.write('// 依据 = analysis/slide_pc.py(真机验证过的正对照求解器); 改判据请先改那边。\n')
    f.write('package com.suw.manager;\n\n')
    f.write('public final class SlideTable {\n')
    f.write('  public static final long TEXT = 0x%xL;\n' % TEXT)
    f.write('  public static final long ETEXT = 0x%xL;\n' % ETEXT)
    f.write('  public static final long STEP = 0x%xL;\n' % STEP)
    f.write('  public static final long[] WIN_START = { %s };\n'
            % ', '.join('0x%xL' % a for a, _, _ in win))
    f.write('  public static final long[] WIN_LEN = { %s };\n'
            % ', '.join('0x%xL' % l for _, l, _ in win))
    f.write('  public static final String[] WIN_NAME = { %s };\n'
            % ', '.join('"%s"' % n for _, _, n in win))
    f.write('  public static final int TOTAL_WIN = 0x%x;   // 合计宽度(字节)\n' % sum(l for _, l, _ in win))
    f.write('}\n')
print('WROTE %s (%d 个窗口, 合计 0x%x 字节)' % (OUT, len(win), sum(l for _, l, _ in win)))
for a, l, n in win:
    print('  %-24s %x +%x' % (n, a, l))
