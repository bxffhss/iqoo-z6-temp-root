#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""stackchan.py —— 在设备同构建的裸 Image 上系统性枚举
"用户数据 → 内核栈(某个栈上局部缓冲)" 的拷贝通道, 并算出该缓冲相对
syscall 入口 SP 的深度, 用来判定能否覆盖 GhostLock 的悬空 rt_waiter。

约定(与 09-24 的文档一致): 地址 = S0 - 深度, S0 = 进入 C 层 syscall 函数时的 sp。
一个缓冲的深度区间 = [Σ - o - L, Σ - o], 其中
  Σ = 从 __arm64_sys_X 到"持有该缓冲的函数 F"路径上所有函数的栈帧之和(含 F),
  o = 缓冲相对 F 的 sp 的偏移, L = 拷贝长度。
只跟 `bl` 边(不跟尾调用 `b`, 尾调用会弹出调用者栈帧, Σ 算法不同)。

用法:
  python stackchan.py probe            # 枚举所有可达通道, 打印落在目标深度窗口的
  python stackchan.py chain <sym>      # 手工核对某条链的每帧大小
"""
import argparse, io, os, re, sys, json, bisect, collections
import numpy as np
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

HERE = os.path.dirname(os.path.abspath(__file__))
KS = os.path.join(HERE, 'kallsyms_g2a88cd145def.txt')
IMG = os.path.join(HERE, 'kernel_dev_g2a88cd145def.bin')
BASE = 0xffffffc010080000
CACHE = os.path.join(HERE, '.stackchan_cache.json')

# 目标: rt_waiter 的 0x50 字节所在深度区间(由 futex 链实测帧算出, 见 main 里的 --window)

def load_syms(path):
    out = []
    for line in io.open(path, encoding='utf-8', errors='replace'):
        p = line.split()
        if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
            out.append((int(p[0], 16), p[1], ' '.join(p[2:])))
    out.sort()
    return out

class Img:
    def __init__(self):
        self.data = io.open(IMG, 'rb').read()
        self.syms = load_syms(KS)
        self.addrs = [s[0] for s in self.syms]
        self.byname = collections.defaultdict(list)
        for a, t, n in self.syms:
            self.byname[n].append(a)
        self.md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
        self.md.detail = True

    def func_at(self, a):
        i = bisect.bisect_right(self.addrs, a) - 1
        if i < 0: return None
        sa, st, sn = self.syms[i]
        if st not in ('t', 'T'): return None
        end = self.addrs[i + 1] if i + 1 < len(self.addrs) else sa + 4
        if a - sa > max(0, end - sa): return None
        return sa, sn, end

    def start_of(self, name):
        v = self.byname.get(name)
        return v[0] if v else None

    def insns(self, addr, count):
        off = addr - BASE
        if off < 0 or off + 4 * count > len(self.data): count = (len(self.data) - off) // 4 - 1
        return list(self.md.disasm(self.data[off:off + 4 * count], addr))

    # ---------- 栈帧大小 ----------
    def frame(self, sa):
        if sa in _FRAME: return _FRAME[sa]
        r = _frame_of(self, sa)
        _FRAME[sa] = r
        return r

    # ---------- bl 边(全表, 只算一次) ----------
    def bl_edges(self):
        if os.path.exists(CACHE):
            j = json.load(io.open(CACHE, encoding='utf-8'))
            return [(a, b) for a, b in j['edges']]
        a = np.frombuffer(self.data[:len(self.data) - len(self.data) % 4], dtype=np.uint32)
        idx = np.nonzero((a & np.uint32(0xFC000000)) == np.uint32(0x94000000))[0]
        imm = (a[idx] & 0x3ffffff).astype(np.int64)
        imm = np.where(imm & (1 << 25), imm - (1 << 26), imm)
        b64 = np.uint64(BASE)
        imm_u = imm.astype(np.uint64)          # 负数以补码回绕, 加法结果仍然正确
        tgt = b64 + idx.astype(np.uint64) * np.uint64(4) + imm_u * np.uint64(4)
        keep = (tgt >= b64) & (tgt < b64 + np.uint64(len(self.data)))
        pc, tg = b64 + idx[keep].astype(np.uint64) * np.uint64(4), tgt[keep]
        # 只保留目标是"某个函数入口"的边
        starts = np.array(self.addrs, dtype=np.uint64)
        pos = np.searchsorted(starts, tg)
        ok = (pos < len(starts)) & (starts[np.clip(pos, 0, len(starts) - 1)] == tg)
        edges = list(zip(pc.tolist(), tg.tolist()))
        edges = [(p, t) for (p, t), k in zip(edges, ok) if k]
        json.dump({'edges': edges}, io.open(CACHE, 'w'))
        return edges

_FRAME = {}

def _opnd(s):
    return s

def _imm_of(opstr, pat):
    m = re.search(pat, opstr)
    return int(m.group(1), 16) if m else None

def _frame_of(IMG, sa, win=24):
    """帧 = 前缀里所有 [sp,#-N]! 预索引压栈的 N + 第一条 sub sp,sp,#N"""
    total = 0
    for ins in IMG.insns(sa, win):
        o = ins.op_str
        if ins.mnemonic in ('stp', 'stpx', 'str', 'stur') and re.search(r'\[sp,\s*#-0x([0-9a-f]+)\]!', o):
            total += int(re.search(r'\[sp,\s*#-0x([0-9a-f]+)\]!', o).group(1), 16)
        if ins.mnemonic == 'sub' and o.startswith('sp, sp, #'):
            total += int(re.search(r'#0x([0-9a-f]+)', o).group(1), 16)
            break
        if ins.mnemonic in ('bl', 'b', 'br', 'ret'):
            break
        if ins.mnemonic == 'add' and o.startswith('sp, sp, #'):
            # 少数编译器用 add sp 收缩, 忽略
            pass
    return total

# ---------- 拷贝原型 ----------
# name -> (dest 寄存器, len 寄存器或固定值)
COPYERS = {
    '_copy_from_user': ('x0', 'x2'),
    'copy_from_user': ('x0', 'x2'),
    'raw_copy_from_user': ('x0', 'x2'),
    'copy_from_user_nofault': ('x0', 'x2'),
    'copy_struct_from_user': ('x0', 'x2'),
    'move_addr_to_kernel': ('x2', 'x1'),
    'memcpy_from_msg': ('x0', 'x2'),
    'copy_msghdr_from_user': ('x0', 0x30),
    'copy_compat_msghdr_from_user': ('x0', 0x30),
    'copy_msghdr_from_user_compat': ('x0', 0x30),
    'strscpy_from_user': ('x0', None),
    'compat_copy_msghdr_from_user': ('x0', 0x30),
}

def track(IMG, sa, call_pc, want_reg):
    """从函数序言正向模拟寄存器 -> sp 偏移; 返回 (offset or None, 说明)"""
    off = {}          # reg -> sp 偏移
    slot = {}         # sp 偏移 -> 该栈槽里存的值的 sp 偏移
    fpbase = None     # x29 = sp + fpbase
    trace = []
    for ins in IMG.insns(sa, max(1, (call_pc - sa) // 4 + 1)):
        m, o = ins.mnemonic, ins.op_str
        parts = [p.strip() for p in o.split(',')]
        dst = parts[0] if parts else ''
        def rd(reg):
            return off.get(reg)
        def wr(reg, val):
            if reg.startswith('w') or reg.startswith('x'):
                r = ('x' + reg[1:]) if reg[0] == 'w' else reg
                off[r] = val
        if m == 'add' and re.fullmatch(r'[xw]\d+, sp, #0x[0-9a-f]+', o):
            reg, _, im = o.split(', '); wr(reg, int(im.lstrip('#'), 16))
        elif m == 'sub' and re.fullmatch(r'[xw]\d+, sp, #0x[0-9a-f]+', o):
            reg, _, im = o.split(', '); wr(reg, -int(im.lstrip('#'), 16))
        elif m == 'add' and re.fullmatch(r'[xw]\d+, x29, #0x[0-9a-f]+', o):
            reg, _, im = o.split(', '); wr(reg, (fpbase or 0) + int(im.lstrip('#'), 16))
        elif m == 'sub' and re.fullmatch(r'[xw]\d+, x29, #0x[0-9a-f]+', o):
            reg, _, im = o.split(', ');
            wr(reg, (fpbase if fpbase is not None else 0) - int(im.lstrip('#'), 16))
        elif m == 'add' and re.fullmatch(r'[xw]\d+, [xw]\d+, #0x[0-9a-f]+', o):
            reg, src, im = [p.strip() for p in o.split(',') if not p.strip().startswith('#')] + \
                           [p.strip() for p in o.split(',') if p.strip().startswith('#')]
            base_v = off.get(src[0] if isinstance(src, list) else src)
            if isinstance(src, str):
                v = off.get(src)
                if v is not None: wr(reg, v + int(im.lstrip('#'), 16))
                else: wr(reg, None)
        elif m == 'sub' and re.fullmatch(r'[xw]\d+, [xw]\d+, #0x[0-9a-f]+', o):
            ps = [p.strip() for p in o.split(',')]
            v = off.get(ps[1])
            if v is not None: wr(ps[0], v - int(ps[2].lstrip('#'), 16))
            else: wr(ps[0], None)
        elif m == 'mov' and re.fullmatch(r'[xw]\d+, [xw]\d+', o):
            d, s = [p.strip() for p in o.split(',')]; wr(d, off.get(s))
        elif m == 'add' and re.fullmatch(r'x29, sp, #0x[0-9a-f]+', o):
            fpbase = int(o.split('#')[1], 16); off['x29'] = fpbase
        if m in ('str', 'stur', 'stp') and '[sp' in o and '!' not in o:
            # 记录栈槽
            im = _imm_of(o, r'\[sp,\s*#0x([0-9a-f]+)\]')
            if im is not None and m in ('str', 'stur'):
                slot[im] = off.get(parts[0])
            elif im is not None and m == 'stp':
                slot[im] = off.get(parts[0]); slot[im + 8] = off.get(parts[1])
        if m in ('ldr', 'ldur') and re.search(r'\[sp,\s*#0x[0-9a-f]+\]', o):
            im = _imm_of(o, r'\[sp,\s*#0x([0-9a-f]+)\]')
            wr(parts[0], slot.get(im))
        # 其它任何对寄存器的写入 -> 失效
        if m not in ('bl', 'b', 'br', 'ret', 'cbz', 'cbnz', 'tbz', 'tbnz', 'b.eq', 'b.ne',
                     'svc', 'nop', 'dmb', 'dsb', 'isb', 'prfm') and dst:
            if re.fullmatch(r'[xw]\d+', dst) and m not in ('add', 'sub', 'mov', 'str', 'stur',
                                                           'stp', 'ldr', 'ldur'):
                wr(dst, None)
        if ins.address == call_pc:
            return off.get(want_reg), fpbase
    return off.get(want_reg), fpbase

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd', nargs='?', default='probe')
    ap.add_argument('arg', nargs='?', default='')
    ap.add_argument('--lo', type=lambda x: int(x, 16), default=0x268)
    ap.add_argument('--hi', type=lambda x: int(x, 16), default=0x2b8)
    ap.add_argument('--maxdepth', type=int, default=6)
    ap.add_argument('--limit', type=int, default=400)
    a = ap.parse_args()
    IMG = Img()
    if a.cmd == 'chain':
        n = int(a.arg, 16) if a.arg.startswith('0x') else IMG.start_of(a.arg)
        sa, sn, end = IMG.func_at(n)
        print("%s frame=0x%x" % (sn, IMG.frame(sa)))
        return
    edges = IMG.bl_edges()
    rev = collections.defaultdict(list)
    for pc, t in edges:
        rev[t].append(pc)
    # 每个函数内的 bl 目标集合
    caller_of = {}
    for pc, t in edges:
        caller_of.setdefault(t, set()).add(pc)

    results = []
    for cname in list(COPYERS):
        cs = IMG.start_of(cname)
        if not cs: continue
        # DFS 向上
        stack = []
        for pc in rev.get(cs, []):
            f = IMG.func_at(pc)
            if not f: continue
            stack.append([(f[0], f[1], pc)])
        seen = 0
        while stack:
            path = stack.pop()
            sa, fname, callpc = path[-1]          # 持有缓冲的最内层函数
            sn = path[0][1]                        # 根 syscall
            if sn.startswith(('__arm64_sys_', 'compat_sys_', '__arm64_compat_sys_', 'SyS_', 'sys_')):
                # 计算 Σ 和缓冲偏移
                total = 0
                for (fsa, fsn, _fpc) in reversed(path):
                    total += IMG.frame(fsa)
                dreg, lreg = COPYERS[cname]
                o, fpb = track(IMG, sa, callpc, dreg)
                L = None
                if isinstance(lreg, int): L = lreg
                else:
                    Lv, _ = track(IMG, sa, callpc, lreg)
                    L = None
                deep = None if o is None else total - o
                print("RAW %-30s %-22s Σ=0x%x o=%s path=%s" % (sn, cname, total, None if o is None else hex(o), ' <- '.join(x[1] for x in path)))
                results.append(dict(syscall=sn, copy=cname, depth_sum=total,
                                    buf=sa, buf_name=fname, o=o, fpbase=fpb, L=L,
                                    path=[(n_, f_) for (_, n_, _), f_ in
                                          zip(path, [IMG.frame(x[0]) for x in path])]))
            elif len(path) < a.maxdepth:
                for pc2 in rev.get(sa, []):
                    f = IMG.func_at(pc2)
                    if not f: continue
                    if any(p[0] == f[0] for p in path): continue
                    stack.append([(f[0], f[1], pc2)] + path)
                    seen += 1
                    if seen > 4000000: break
            if len(results) > a.limit: break
        if len(results) > a.limit: break

    print("候选通道 %d 条 (目标深度窗口 [%s,%s])" % (len(results), hex(a.lo), hex(a.hi)))
    hit = 0
    for r in results:
        if r['o'] is None: continue
        deep = r['depth_sum'] - r['o']
        if deep < a.lo or deep > a.hi + 0x10:
            continue
        hit += 1
        print("  ★ %-34s copy=%-22s Σ=0x%x o=0x%x deep=0x%x path=%s" % (
            r['syscall'], r['copy'], r['depth_sum'], r['o'], deep,
            ' <- '.join("%s(0x%x)" % (n, f) for n, f in r['path'])))
    print("落在窗口内: %d" % hit)
    # 另外打印"接近"的(top 40 by |deep-hi|)
    cand = []
    for r in results:
        if r['o'] is None: continue
        deep = r['depth_sum'] - r['o']
        cand.append((abs(deep - a.hi), deep, r))
    cand.sort()
    print("--- 最接近窗口的 40 条 ---")
    for d, deep, r in cand[:40]:
        print("  deep=0x%-5x (差 %+d) %-32s %-22s Σ=0x%x o=0x%x L=%s" % (
            deep, deep - a.hi, r['syscall'], r['copy'], r['depth_sum'], r['o'],
            hex(r['L']) if r['L'] else '?'))

main()
