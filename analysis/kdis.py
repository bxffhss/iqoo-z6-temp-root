#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""kdis.py —— 对**裸 ARM64 Image** 做符号感知反汇编/搜索（capstone 版）。

存在的理由: 这个项目的 kernel 是从 boot.img 里剥出来的裸 Image，
llvm-objdump 会把它误认成 coff-arm64 而什么都不输出；而设备同构建的符号表
是内嵌 kallsyms 提取出来的文本，不是 ELF。所以需要一个"给符号名/地址就能反汇编"的小工具。

用法:
  python kdis.py --ks <kallsyms.txt> --img <kernel.bin> --base 0xffffffc010080000 <子命令>
子命令:
  sym <name>              打印符号地址(可多个)
  dis <name|地址> [条数]  反汇编
  callers <name> [上限]   线性扫全文找 `bl <该符号>` 的调用点(按符号定界统计)
  refs <全局符号>         找 adrp+add / adrp+ldr 中指向该 4K 页的引用(定位"谁在用这个全局")
说明: 线性扫全文是**全 44MB** 的近似扫描(反汇编所有指令)，几分钟；
      已按需要缓存到 .kdis_cache.json(仅 refs/callers 用)。
"""
import argparse, io, os, re, sys, json, bisect
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

def load_ks(path):
    syms = []                      # (addr, type, name)
    for line in io.open(path, encoding='utf-8', errors='replace'):
        p = line.split()
        if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
            syms.append((int(p[0], 16), p[1], ' '.join(p[2:])))
    syms.sort()
    return syms

class Kernel:
    def __init__(self, img, ks, base):
        self.data = io.open(img, 'rb').read()
        self.base = base
        self.syms = load_ks(ks)
        self.addrs = [s[0] for s in self.syms]
        self.md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
        self.md.detail = True
    def addr_of(self, name):
        for a, t, n in self.syms:
            if n == name or n.split('$')[0] == name:
                return a
        return None
    def name_of(self, a):
        i = bisect.bisect_right(self.addrs, a) - 1
        if i < 0: return None
        sa, st, sn = self.syms[i]
        d = a - sa
        lim = (self.addrs[i+1] - sa) if i + 1 < len(self.addrs) else 0
        return "%s+0x%x (符号起于 0x%x, 下一符号在 %+d 字节内)" % (sn, d, sa, lim)
    def disasm(self, start, count):
        off = start - self.base
        if off < 0 or off + 4*count > len(self.data):
            raise SystemExit("地址越界: 0x%x off=0x%x" % (start, off))
        out = []
        for ins in self.md.disasm(self.data[off:off+4*count], start):
            note = ''
            m = re.search(r'#(0x[0-9a-f]+)', ins.op_str)
            if ins.mnemonic in ('bl', 'b') and m:
                t = int(m.group(1), 16)
                nm = self.name_of(t)
                if nm: note = '   ; -> ' + nm
            elif m:
                t = int(m.group(1), 16)
                for a, ty, n in self.syms:
                    if a == t: note = '   ; = %s' % n; break
            out.append("  %x: %-10s %-28s%s" % (ins.address, ins.mnemonic, ins.op_str, note))
        return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ks', default=r'G:\项目\Windows管理\usb\临时root\analysis\kallsyms_g2a88cd145def.txt')
    ap.add_argument('--img', default=r'G:\项目\Windows管理\usb\临时root\analysis\kernel_dev_g2a88cd145def.bin')
    ap.add_argument('--base', default='0xffffffc010080000')
    sub = ap.add_subparsers(dest='cmd', required=True)
    for name, nargs in (('sym', 1), ('dis', 2), ('refs', 1), ('callers', 1)):
        s = sub.add_parser(name); s.add_argument('target'); s.add_argument('n', nargs='?', default='40')
    a = ap.parse_args()
    K = Kernel(a.img, a.ks, int(a.base, 16))

    if a.cmd == 'sym':
        for nm in a.target.split(','):
            v = K.addr_of(nm)
            print("%-32s %s" % (nm, "0x%x" % v if v else "缺"))
    elif a.cmd == 'dis':
        t = a.target
        start = int(t, 16) if t.startswith('0x') else K.addr_of(t)
        if not start: print("找不到符号", t); return
        print("@", K.name_of(start))
        for l in K.disasm(start, int(a.n)): print(l)
    elif a.cmd in ('refs', 'callers'):
        tgt = a.target if a.target.startswith('0x') else K.addr_of(a.target)
        if not tgt: print("找不到符号", a.target); return
        page = tgt & ~0xfff
        want = (tgt if a.cmd == 'callers' else page)
        hits, n, buf = [], 0, K.data
        md2 = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
        step = 4
        off = 0
        end = len(buf)
        while off < end - 4:
            ins = int.from_bytes(buf[off:off+4], 'little')
            ok = False
            if (ins & 0x9f000000) == 0x90000000:           # adrp: 1 immlo2 immhi19 10000 rd5
                immlo = (ins >> 29) & 3; immhi = (ins >> 5) & 0x7ffff
                imm = ((immhi << 2) | immlo)
                imm -= (1 << 21) if imm & (1 << 20) else 0
                ad = ((K.base + off) & ~0xfff) + (imm << 12)   # ADRP 目标基于**页对齐**的 PC
                if a.cmd == 'refs' and ad == page:
                    ok = True
            elif (ins & 0xfc000000) == 0x94000000:         # bl
                imm26 = ins & 0x3ffffff
                imm26 -= (1 << 26) if imm26 & (1 << 25) else 0
                if K.base + off + imm26 * 4 == want: ok = True
            if ok:
                pc = K.base + off
                hits.append((pc, K.name_of(pc)))
                n += 1
                if n >= int(a.n): break
            off += step
        for pc, nm in hits: print("  0x%x  in %s" % (pc, nm))
        print("命中 %d 处 (%s=%s)" % (len(hits), a.cmd, hex(tgt)))

main()
