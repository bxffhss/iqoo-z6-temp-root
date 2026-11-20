#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""stackdepth.py —— 找"用户数据被拷进某个内核栈局部缓冲"的全部通道, 并算出该缓冲
相对 syscall 入口 SP 的深度区间, 用来判定能不能盖住 GhostLock 的悬空 rt_waiter。

模型(与 GHOST-TRIGGER-SOLVED §3 一致): 地址 = S0 - 深度。
  Σ(F) = 从某个 __arm64_sys_* 根到 F 的调用链上所有函数栈帧之和(含 F)。
  F 里 `bl copy(..., dst = sp + o, ...)` ⇒ 缓冲**最深字节**在深度 Σ(F) - o,
  向浅处延伸 L 字节 ⇒ 覆盖 [Σ-o-L, Σ-o]。
尾调用 `b func` 会把调用者的栈帧先弹出, 所以继承 Σ 时要减去调用者帧。

用法:
  python stackdepth.py build          # 建帧表+边表(缓存到 .stackdepth_cache.json.gz)
  python stackdepth.py relax          # 求每个函数的最大 Σ 并列出候选拷贝点
  python stackdepth.py show <sym>     # 打印某函数的帧/拷贝点/父链
"""
import argparse, bisect, collections, glob, gzip, io, json, os, re, sys
import numpy as np
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

HERE = os.path.dirname(os.path.abspath(__file__))
KS = os.path.join(HERE, 'kallsyms_g2a88cd145def.txt')
IMG = os.path.join(HERE, 'kernel_dev_g2a88cd145def.bin')
BASE = 0xffffffc010080000
CACHE = os.path.join(HERE, '.stackdepth_cache.json.gz')

# dst/len 参数位置(按 5.4 原型)
COPIERS = {
    '_copy_from_user': (0, 2), 'copy_from_user': (0, 2), 'raw_copy_from_user': (0, 2),
    'copy_from_user_nofault': (0, 2), 'copy_struct_from_user': (0, 2),
    'move_addr_to_kernel': (2, 1), 'memcpy_from_msg': (0, 2),
    'copy_msghdr_from_user': (0, None), 'copy_compat_msghdr_from_user': (0, None),
    'compat_copy_msghdr_from_user': (0, None), 'strscpy_from_user': (0, None),
    'get_compat_msghdr': (0, None), '__copy_to_user': None,
    'strncpy_from_user': (0, 1), 'compat_standard_from_user': (0, 1),
    'iov_iter_copy_from_user': (0, None), 'input_ff_effect_from_user': (1, None),
    '__kfifo_from_user': (0, None), 'kstrtouint_from_user': (0, None),
    'copy_arg_from_user': (0, None), 'compat_ptr': None,
}
ROOTPAT = re.compile(r'^(__arm64_sys_|__arm64_compat_sys_|compat_sys_|SyS_)')
# 通用"从用户态拷数据"的名字模式 + 少量参数位置修正
COPYPAT = re.compile(r'(from_user|move_addr_to_kernel|memcpy_from_msg|copy_msghdr_from_user)')
COPIER_ARG = {'move_addr_to_kernel': 2, 'compat_standard_from_user': 1, 'input_ff_effect_from_user': 1,
              '__kfifo_from_user': 1, 'copy_ctl_value_from_user': 1, 'iov_iter_copy_from_user': 0,
              'bio_copy_user_iov': 0, 'strscpy_from_user': 0, 'copy_arg_from_user': 0,
              'compat_ptr': None, '__copy_to_user': None, 'copy_from_user_toio': None,
              'arch_perf_out_copy_user': None, 'binder_alloc_copy_user_to_buffer': 0}

def is_copier(nm):
    if nm in COPIER_ARG:
        return COPIER_ARG[nm] is not None
    return bool(COPYPAT.search(nm)) and 'to_user' not in nm

def dst_reg(nm):
    return 'x%d' % COPIER_ARG.get(nm, 0)

def load_syms(path):
    out = []
    for line in io.open(path, encoding='utf-8', errors='replace'):
        p = line.split()
        if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
            out.append([int(p[0], 16), p[1], ' '.join(p[2:])])
    out.sort()
    return out

class K:
    def __init__(self, load=True):
        self.data = io.open(IMG, 'rb').read()
        self.syms = load_syms(KS)
        self.addrs = [s[0] for s in self.syms]
        self.md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
        self.md.detail = True
        self.name = {}      # start addr -> name
        self.end = {}       # start addr -> end addr
        for i, (a, t, n) in enumerate(self.syms):
            if t in ('t', 'T'):
                self.name[a] = n
                self.end[a] = self.addrs[i + 1] if i + 1 < len(self.addrs) else a + 4
        self.byname = collections.defaultdict(list)
        for a, n in self.name.items():
            self.byname[n].append(a)
        if load and os.path.exists(CACHE) and os.path.getsize(CACHE) > 100:
            j = json.load(gzip.open(CACHE, 'rt'))
            self.frames = {int(k): v for k, v in j['frames'].items()}
            self.edges = j['edges']          # [[caller, callee, pc, kind]]
        else:
            self.frames = {}
            self.edges = None

    def save(self):
        blob = json.dumps({'frames': self.frames, 'edges': self.edges}).encode('utf-8')
        with gzip.open(CACHE, 'wb') as fh:
            fh.write(blob)

    def f_at(self, a):
        i = bisect.bisect_right(self.addrs, a) - 1
        if i < 0: return None
        sa = self.addrs[i]
        if sa not in self.name or a >= self.end[sa]: return None
        return sa

    def insns(self, addr, count):
        off = addr - BASE
        n = min(count, (len(self.data) - off) // 4 - 1, (self.end.get(self.f_at(addr) or 0, addr + 4 * count) - addr) // 4)
        if off < 0 or n <= 0: return []
        return list(self.md.disasm(self.data[off:off + 4 * n], addr))

    # ---- 栈帧 ----
    def frame(self, sa):
        if sa in self.frames: return self.frames[sa]
        total, fpb = 0, 0
        for ins in self.insns(sa, 16):
            o = ins.op_str
            m = re.search(r'\[sp,\s*#-0x([0-9a-f]+)\]!', o)
            if ins.mnemonic in ('stp', 'str', 'sturb', 'sttr') and m:
                total += int(m.group(1), 16)
                continue
            if ins.mnemonic == 'sub' and o.startswith('sp, sp, #'):
                total += int(re.search(r'#0x([0-9a-f]+)', o).group(1), 16)
                continue
            if ins.mnemonic == 'add' and o.startswith('x29, sp, #'):
                fpb = int(re.search(r'#0x([0-9a-f]+)', o).group(1), 16)
            if ins.mnemonic in ('bl', 'b', 'br'):
                break
        r = (total, fpb)
        self.frames[sa] = r
        return r

    def build_edges(self):
        a = np.frombuffer(self.data[:len(self.data) - len(self.data) % 4], dtype=np.uint32)
        starts = np.array(self.addrs, dtype=np.uint64)
        edges = []
        for mn, top in (('bl', 0x94000000), ('b', 0x14000000)):
            sel = (a & np.uint32(0xFC000000)) == np.uint32(top)
            idx = np.nonzero(sel)[0]
            imm = (a[idx] & np.uint32(0x3ffffff if mn == 'bl' else 0x3ffffff)).astype(np.int64)
            sh = 26
            imm = np.where(imm & (1 << (sh - 1)), imm - (1 << sh), imm)
            pc = np.uint64(BASE) + idx.astype(np.uint64) * np.uint64(4)
            tgt = pc + imm.astype(np.uint64) * np.uint64(4)
            pos = np.searchsorted(starts, tgt)
            ok = (pos < len(starts)) & (starts[np.clip(pos, 0, len(starts) - 1)] == tgt)
            for p, t in zip(pc[ok].tolist(), tgt[ok].tolist()):
                c = self.f_at(p)
                if c is None: continue
                edges.append([c, t, p, mn])
        self.edges = edges
        return edges

    # ---- 反向解析寄存器 -> sp 偏移 ----
    def resolve(self, reg, pc, hop=0, lo=None, start=None):
        lo = lo if lo is not None else (start or 0)
        for ins in reversed(self.insns(lo, (pc - lo) // 4 + 1) if start else []):
            pass
        ins_list = list(self.insns(lo, (pc - lo) // 4 + 1))
        fpb = self.frame(lo)[1]
        for ins in reversed(ins_list):
            if ins.address >= pc: continue
            ps = [p.strip() for p in ins.op_str.split(',')]
            if not ps or not re.fullmatch(r'[wx]\d+', ps[0]): continue
            d = ps[0]
            dn = 'x' + d[1:] if d[0] == 'w' else d
            rn = 'x' + reg[1:] if reg[0] == 'w' else reg
            if dn != rn: continue
            m = ins.mnemonic
            if m == 'add' and ps[1] == 'sp':
                return int(ps[2].lstrip('#'), 16)
            if m == 'sub' and ps[1] == 'sp':
                return -int(ps[2].lstrip('#'), 16)
            if m == 'add' and ps[1] == 'x29':
                return fpb + int(ps[2].lstrip('#'), 16)
            if m == 'sub' and ps[1] == 'x29':
                return fpb - int(ps[2].lstrip('#'), 16)
            if m in ('mov', 'movi') and len(ps) == 2 and re.fullmatch(r'[wx]\d+', ps[1]):
                return self.resolve(ps[1], ins.address, hop + 1, lo) if hop < 8 else None
            if m in ('add', 'sub') and len(ps) == 3 and re.fullmatch(r'[wx]\d+', ps[1])                and ps[2].startswith('#'):
                v = self.resolve(ps[1], ins.address, hop + 1, lo) if hop < 8 else None
                if v is None: return None
                im = int(ps[2].lstrip('#'), 16)
                return v + im if m == 'add' else v - im
            if m == 'mov' and len(ps) == 3 and ps[1] == 'sp' :
                return 0
            if m in ('orr',) and len(ps) == 3 and re.fullmatch(r'[wx]\d+', ps[1]) and ps[2] == 'xzr':
                return self.resolve(ps[1], ins.address, hop + 1, lo) if hop < 8 else None
            if m in ('ldr', 'ldur') and ps[1].startswith('[sp'):
                im = re.search(r'#0x([0-9a-f]+)', ps[1])
                if not im: return None
                slot = int(im.group(1), 16)
                for ins2 in reversed(ins_list):
                    if ins2.address >= ins.address: continue
                    p2 = [p.strip() for p in ins2.op_str.split(',')]
                    if ins2.mnemonic in ('str', 'stur') and len(p2) >= 2 and p2[1].startswith('[sp'):
                        im2 = re.search(r'#0x([0-9a-f]+)', p2[1])
                        if im2 and int(im2.group(1), 16) == slot and hop < 6:
                            return self.resolve(p2[0], ins2.address, hop + 1, lo)
                    if ins2.mnemonic == 'stp' and len(p2) >= 3 and p2[2].startswith('[sp'):
                        im2 = re.search(r'#0x([0-9a-f]+)', p2[2])
                        if not im2: continue
                        s2 = int(im2.group(1), 16)
                        if s2 == slot and hop < 6: return self.resolve(p2[0], ins2.address, hop + 1, lo)
                        if s2 + 8 == slot and hop < 6: return self.resolve(p2[1], ins2.address, hop + 1, lo)
                return None
            return None           # 不透明的写入
        return None

    def resolve_const(self, reg, pc, lo, hop=0):
        """反向求一个寄存器的立即数值(找不到返回 None)。遇到 bl/br 即停(可能被别处改写)。"""
        ins_list = list(self.insns(lo, (pc - lo) // 4 + 1))
        rn = 'x' + reg[1:] if reg and reg[0] == 'w' else reg
        for ins in reversed(ins_list):
            if ins.address >= pc: continue
            if ins.mnemonic in ('bl', 'blr', 'br', 'ret'): return None
            ps = [p.strip() for p in ins.op_str.split(',')]
            if not ps or not re.fullmatch(r'[wx]\d+', ps[0]): continue
            d = 'x' + ps[0][1:] if ps[0][0] == 'w' else ps[0]
            if d != rn: continue
            if ins.mnemonic in ('mov', 'movz') and len(ps) == 2 and ps[1].startswith('#'):
                return int(ps[1].lstrip('#'), 16)
            if ins.mnemonic == 'mov' and len(ps) == 2 and re.fullmatch(r'[wx]\d+', ps[1]):
                return self.resolve_const(ps[1], ins.address, lo, hop + 1) if hop < 6 else None
            if ins.mnemonic == 'lsl' and len(ps) == 3 and ps[1].startswith('#'):
                v = self.resolve_const(ps[2], ins.address, lo, hop + 1)
                return None if v is None else v << int(ps[1].lstrip('#'), 16)
            if ins.mnemonic == 'movk':
                return None
            return None
        return None

    def copysites(self, sa):
        """返回该函数里所有 (call_pc, copy_name, dst_sp_off, len_off_or_None)"""
        out = []
        for ins in self.insns(sa, (self.end[sa] - sa) // 4):
            if ins.mnemonic != 'bl': continue
            t = self.f_at(int(re.search(r'#(0x[0-9a-f]+)', ins.op_str).group(1), 16) if '#' in ins.op_str else 0)
            tgt = None
            m = re.search(r'#(0x[0-9a-f]+)', ins.op_str)
            if m: tgt = self.name.get(int(m.group(1), 16))
            if not tgt or tgt not in COPIERS or COPIERS[tgt] is None: continue
            di, li = COPIERS[tgt]
            dreg = 'x%d' % di
            off = self.resolve(dreg, ins.address, 0, sa)
            out.append((ins.address, tgt, off))
        return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd', default='relax', nargs='?')
    ap.add_argument('arg', nargs='?', default='')
    ap.add_argument('--lo', default='0x268'); ap.add_argument('--hi', default='0x2b8')
    ap.add_argument('--minlen', default='0x10')
    a = ap.parse_args()
    lo, hi = int(a.lo, 16), int(a.hi, 16)
    K_ = K()
    if a.cmd == 'build':
        K_.build_edges(); [K_.frame(s) for s in K_.name]
        K_.save(); print("frames=%d edges=%d" % (len(K_.frames), len(K_.edges)))
        return
    if K_.edges is None:
        K_.edges = K_.build_edges()
        print("(边表现场构建)", len(K_.edges))
    # 邻接: caller -> [(callee, pc)]
    adj = collections.defaultdict(list)
    for c, t, pc, kind in K_.edges:
        adj[c].append((t, pc, kind))
    copyaddr = {a: n for a, n in K_.name.items() if is_copier(n)}
    CC = set()
    for c, t, pc, kind in K_.edges:
        if t in copyaddr: CC.add(c)
    radj = collections.defaultdict(set)
    for c, t, pc, kind in K_.edges:
        radj[t].add(c)
    can = set(CC); fr = list(CC)
    while fr:
        x = fr.pop()
        for p in radj.get(x, ()):
            if p not in can:
                can.add(p); fr.append(p)
    print("含拷贝调用的函数 %d, 能到达它们的函数 %d" % (len(CC), len(can)))
    adjc = {}
    for c, t, pc, kind in K_.edges:
        if t in can:
            adjc.setdefault(c, []).append((t, kind))
    sitec = {}
    def sites_of(c):
        if c not in sitec:
            r = []
            for (t, pc, kind) in adj.get(c, []):
                if t in copyaddr:
                    dd = dst_reg(copyaddr[t])
                    off = K_.resolve(dd, pc, 0, c)
                    lr = 'x1' if COPIER_ARG.get(copyaddr[t], 0) == 2 else 'x2'
                    Ln = K_.resolve_const(lr, pc, 0, c)
                    r.append((pc, copyaddr[t], off, Ln))
            sitec[c] = r
        return sitec[c]
    FRAM = {s: K_.frame(s)[0] for s in K_.name}
    rows = []; npath = 0; nnode = 0
    for root in [a for a, n in K_.name.items() if ROOTPAT.match(n)]:
        f0 = FRAM[root]
        if f0 == 0 or f0 > 0x700: continue
        stack = [(root, f0, 0, ())]
        while stack:
            cur, sg, lvl, anc = stack.pop()
            nnode += 1
            if lvl < 9:
                for (pc, cn, off, Ln) in sites_of(cur):
                    npath += 1
                    if off is None: continue
                    deep = sg - off
                    if deep < 0x100 or deep > 0x700: continue
                    covlo = deep - (Ln - 1) if Ln else None
                    if deep < lo:
                        verdict = 'too-shallow'
                    elif (deep - hi) % 8:
                        verdict = 'misaligned'
                    elif covlo is None:
                        verdict = 'L?'
                    elif covlo <= lo:
                        verdict = 'PASS'
                    else:
                        verdict = 'too-deep-or-short(L=%s need>=%s)' % (hex(Ln), hex(deep - lo + 1))
                    rows.append("%s\t%s\t0x%x\t0x%x\t0x%x\t%s\t%s\t0x%x\t%s\t%s" %
                                (K_.name[root], K_.name[cur], sg, off, deep, cn,
                                 'ALGN' if (deep - hi) % 8 == 0 else 'a%d' % ((deep - hi) % 8), pc,
                                 '?' if Ln is None else hex(Ln), verdict))
            if lvl >= 9: continue
            for (t, kind) in adjc.get(cur, ()):
                if t in anc: continue
                ft = FRAM[t]
                if ft == 0: continue
                nsg = (sg - FRAM[cur] + ft) if kind == 'b' else (sg + ft)
                if nsg > 0x700: continue
                stack.append((t, nsg, lvl + 1, anc + (cur,)))
    io.open(os.path.join(HERE, 'stackchan_dump.tsv'), 'w', encoding='utf-8').write(
        "\n".join(sorted(set(rows))) + "\n")
    print("DFS 节点 %d, 检查站点 %d, 输出候选 %d 行 -> stackchan_dump.tsv" % (nnode, npath, len(set(rows))))


main()
