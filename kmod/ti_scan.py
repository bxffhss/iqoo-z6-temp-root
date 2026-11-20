#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ti_scan.py —— 用 `mrs xN, SP_EL0` 之后的访存指令，把**设备上 thread_info/task_struct 前段**
的字段偏移直接从内核自己的代码里量出来（不依赖任何源码/树）。

原理：arm64 的 `current` 就是 `mrs xN, SP_EL0`（THREAD_INFO_IN_TASK ⇒ thread_info 在
task_struct 偏移 0，两者同一个基址）。凡是用 current 的代码都编译成 `ldr/str [xN, #imm]`，
所以 **imm 的直方图 = 内核真的在读写哪些偏移**。这正好回答两件事：
  ① δ=+56 到底落在 thread_info 里(偏移 < 0x60 有很多活跃槽)，还是 ti 之后插了字段；
  ② KSU/路线 A 要用的 `test_thread_flag`、`preempt_count`、`restart_block` 偏移 = 设备实测值。
偏移口径：THREAD_SIZE=16K，`ti->flags` 上游在 0x00、`preempt_count` 0x08。

用法：python kmod/ti_scan.py [text起点符号=_text] [条数上限=0=全部]
产物：stdout(建议重定向到 kmod/layout/ti_scan.txt)
"""
import io, os, re, sys, struct, bisect, collections
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

HERE = os.path.dirname(os.path.abspath(__file__))
AN = os.path.join(HERE, "..", "analysis")
IMG = os.path.join(AN, "kernel_dev_g2a88cd145def.bin")
KS = os.path.join(AN, "kallsyms_g2a88cd145def.txt")
BASE = 0xffffffc010080000
MRS_SP_EL0 = 0xd5384100          # mrs x<Rt>, SP_EL0 —— **一手核对**：
                                 # remove_waiter+0x38 处 `mrs x20, sp_el0` 的原词 = 0xd5384114
                                 # (0xd5384200 是我先前记错的值，全 text 只命中 1 次就是证据)
MASK_NO_RT = 0xffffffe0          # bits[9:5] 必须为 0，低 5 位是 Rt

data = io.open(IMG, "rb").read()
syms = []
for line in io.open(KS, encoding="utf-8", errors="replace"):
    p = line.split()
    if len(p) >= 3 and re.fullmatch(r"[0-9a-f]{16}", p[0]):
        syms.append((int(p[0], 16), p[1], " ".join(p[2:])))
syms.sort()
addrs = [s[0] for s in syms]
idx = {n: a for a, t, n in syms}


def addr_of(name):
    return idx.get(name)


def name_of(a):
    i = bisect.bisect_right(addrs, a) - 1
    if i < 0:
        return hex(a)
    return "%s(%s)+0x%x" % (syms[i][2], syms[i][1], a - syms[i][0])


t0 = addr_of(sys.argv[1] if len(sys.argv) > 1 else "_text")
et = addr_of("_etext")
if t0 is None or et is None:
    print("符号表里没有 _text/_etext")
    sys.exit(1)
o0, o1 = t0 - BASE, et - BASE
print(f"# _text={t0:#x} .. _etext={et:#x}  ({(o1-o0)/1024/1024:.1f} MB)  图 {len(data)/1024/1024:.1f} MB")

md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
md.detail = True

hist = collections.Counter()          # 偏移 -> 次数
who = collections.defaultdict(collections.Counter)   # 偏移 -> 所在函数
nsp = 0
LIMIT = int(sys.argv[2]) if len(sys.argv) > 2 else 0
off = o0
while off + 4 <= o1:
    if LIMIT and nsp >= LIMIT:
        break
    w = struct.unpack_from("<I", data, off)[0]
    if (w & MASK_NO_RT) != MRS_SP_EL0:
        off += 4
        continue
    rt = w & 0x1f
    va = BASE + off
    nsp += 1
    # 往后看：只承认"基址寄存器没被改写"的第一次访存。
    # (不加这条会出现假账：mrs 之后 xN 被重新赋值，随后 [xN,#imm] 量的就不是 current)
    for ins in md.disasm(data[off + 4: off + 4 + 48], va + 4):
        m = ins.mnemonic
        is_acc = (m.startswith("ldr") or m.startswith("str") or m.startswith("ldp")
                  or m.startswith("stp") or m.startswith("ldar") or m.startswith("stlr"))
        if is_acc:
            mm = re.search(r"\[\s*x(\d{1,2})\s*(?:,\s*#(-?0x[0-9a-f]+|-?\d+))?\s*\]", ins.op_str)
            if mm and int(mm.group(1)) == rt:
                base_imm = 0 if not mm.group(2) else int(mm.group(2), 0)
                hist[base_imm] += 1
                who[base_imm][name_of(va)] += 1
            break                      # 遇到任何访存就结束本处(承认或不记账)
        if rt in ins.regs_write:       # 基址被改写 ⇒ 这处的账不能记
            break
        if m in ("b", "br", "ret", "bl", "blr", "cbz", "cbnz", "tbz", "tbnz", "svc"):
            break
    off += 4

print(f"# mrs SP_EL0 命中 {nsp} 处，其中紧跟访存的 {sum(hist.values())} 处")
print("\n=== 偏移直方图(全部) ===")
for k in sorted(hist):
    print(f"0x{k:03x} ({k:>5})  {hist[k]:>6} 次   如: " +
          ", ".join(f"{n}" for n, _ in who[k].most_common(2)))
print("\n=== 只看 thread_info 前段(偏移 < 0x60) ===")
lo = {k: v for k, v in hist.items() if 0 <= k < 0x60}
for k in sorted(lo):
    print(f"  0x{k:03x}  {lo[k]:>6} 次")
print(f"  小计 {sum(lo.values())} / 全部 {sum(hist.values())}")
print("\n=== 对照:已实测的 task_struct 锚点是否出现在这里 ===")
for nm, o in [("state", 0x60), ("stack", 0x68), ("usage", 0x70), ("flags", 0x74),
              ("ptrace", 0x78), ("wake_entry", 0x80), ("prio", 0xb4),
              ("sched_task_group", 0x418), ("active_mm", 0x5e8),
              ("real_parent", 0x6a0), ("parent", 0x6a8), ("thread_pid", 0x6f8),
              ("real_cred", 0x840), ("cred", 0x848), ("fs", 0x870), ("files", 0x878),
              ("nsproxy", 0x880), ("signal", 0x888), ("sighand", 0x890),
              ("pi_blocked_on", 0x940)]:
    print(f"  {nm:<18}{o:#06x}  {'命中 ' + str(hist[o]) + ' 次' if o in hist else '—'}")
maxlo = max([k for k in hist if k >= 0], default=0)
print(f"\n# 见到的最大正偏移 = {maxlo:#x}")
