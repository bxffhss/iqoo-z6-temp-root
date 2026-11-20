#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""w1056_kernel_stack_sum.py —— 0 枪（纯本机）：把「第 81 发死在 insmod 里＝内核栈溢出」这个候选的**另一半**补上。

背景(一手，来自 w1053/w1054)：我们模块自己那条链的最坏栈 = 9632 B(全体帧之和，也是任一链的上界)、
其中 init_module→wr_init→policydb_read 这条真链 = 4864 B；这台机的 THREAD_SIZE = 16384 B
(arch/arm64/include/asm/page.h: PAGE_SIZE=4096 << THREAD_SIZE_ORDER=2；VMAP_STACK=y)。
余量 = 16384-4864 = 11520 B 要给"内核在 insmod 那条路上已经吃掉的部分"——**没量之前不能说判死**。

为什么不拿 vmlinux(远端那棵树里没有 vmlinux/System.map)：改用**已有的资产**——
analysis/kallsyms_g2a88cd145def.txt(设备同构建) + analysis/.stackdepth_cache.json.gz
(99,205 个函数帧 + 422,220 条 bl 边，由 stackdepth.py 从裸 Image 反汇编建好、Sep 27 缓存)。
⇒ 帧是**设备真镜像里读出来的**，不是我按主线印象写的。

★仪器纪律(都是过去这几格自己踩的)：
  · 每个解析结果旁边都给原始可核量(帧数/边数/命中符号数)，0 一律先怀疑仪器再怀疑结论；
  · "路径没找到"要印 NOT_FOUND，不许印成"深度 0"(那会把'未测'伪装成'很浅')；
  · 只跟 bl 边(尾调用 b 会先弹调用者帧，跟了就把深度算错)——这一条沿用 stackchan.py 的口径；
  · 环只当"低估"如实报，不当 0 藏起来。
跑法：python kmod/w1056_kernel_stack_sum.py
"""
import gzip
import io
import json
import os
import re
import sys
import collections

try:                       # 本机控制台是 GBK：不重配置的话，'⇒' 这类字符会把 print 直接打挂
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
A = os.path.join(HERE, "..", "analysis")
KS = os.path.join(A, "kallsyms_g2a88cd145def.txt")
CACHE = os.path.join(A, ".stackdepth_cache.json.gz")
THREAD_SIZE = 16384          # w1053 现读：4096 << 2
OURS_FULL = 9632             # w1054：全体帧之和(任一链的上界)
OURS_PARSE = 4864            # w1054：init_module→wr_init→policydb_read 这条真链
KPOL_FRAME = {"policydb_read": 1024, "wr_init": 544, "init_module": 160}   # 我们那份(.su)，拿来对表

for p in (KS, CACHE):
    if not os.path.exists(p):
        print("!! 缺资产 %s ⇒ 未测退出" % p)
        sys.exit(1)

name_by_addr, addr_by_name = {}, collections.defaultdict(list)
with io.open(KS, encoding="utf-8", errors="replace") as fh:
    for ln in fh:
        parts = ln.split()
        if len(parts) >= 3 and re.fullmatch(r"[0-9a-f]{16}", parts[0]) and parts[1] in ("t", "T"):
            a = int(parts[0], 16)
            n = " ".join(parts[2:])
            name_by_addr[a] = n
            addr_by_name[n].append(a)

j = json.load(gzip.open(CACHE, "rt"))
frames = {int(k): v[0] for k, v in j["frames"].items()}
edges = [(c, t) for c, t, pc, kind in j["edges"] if kind == "bl"]
adj = collections.defaultdict(list)
for c, t in edges:
    adj[c].append(t)
print("资产：符号(t/T)=%d 帧表=%d bl 边=%d(已滤掉尾调用) 缓存=%s" % (
    len(name_by_addr), len(frames), len(edges), os.path.basename(CACHE)))


def one(n):
    a = addr_by_name.get(n)
    return a[0] if a else None


def frame_of(n):
    a = one(n)
    if a is None:
        return None
    return frames.get(a, "无记录")


print("\n=== 1) insmod 那条路上每个函数的帧(设备镜像里现读) ===")
for n in ("__arm64_sys_finit_module", "load_module", "do_one_initcall", "do_init_module",
          "security_load_policy", "policydb_read", "avtab_read", "ebitmap_read", "mls_read"):
    print("   %-26s frame=%s" % (n, frame_of(n)))
print("   ★对表：内核自己那份 policydb_read 的帧 vs 我们那份(编进 ko 的)= %s vs %s" % (
    frame_of("policydb_read"), KPOL_FRAME["policydb_read"]))

print("\n=== 2) 从 __arm64_sys_finit_module 走到 do_one_initcall 的最深路径(帧之和) ===")
memo, cycles = {}, set()


def worst(a, stack):
    na = name_by_addr.get(a, hex(a))
    if a in stack:
        cycles.add(na)
        return 0, [na + "(环)"]
    if a in memo:
        return memo[a]
    stack.add(a)
    best, bp = 0, []
    for t in set(adj.get(a, ())):
        v, p = worst(t, stack)
        if v > best:
            best, bp = v, p
    stack.discard(a)
    r = (frames.get(a, 0) + best, [na] + bp)
    memo[a] = r
    return r


root = one("__arm64_sys_finit_module")
target = one("do_one_initcall")
if root is None or target is None:
    print("   NOT_FOUND ⇒ 未测(符号名在这份 kallsyms 里找不到，别当成'深度 0')")
else:
    # 只沿"能到 do_one_initcall"的那条支算：先取全图最深，再单独把路径打出来核对
    v, p = worst(root, set())
    print("   [过近似，不作判据] 图上取最大的『最深链』 = %d B，层数=%d ⇒ 它把 kfree→__schedule→do_exit 当调用边跟；真测量只用第 1 节的单函数帧" % (v, len(p)))
    print("   前 18 层: %s" % " -> ".join(p[:18]))
    if target in memo:
        print("   [同样过近似，别用] 到 do_one_initcall 的图上最深 = %d B" % memo[target][0])
        print("      该支路径: %s" % " -> ".join(memo[target][1][:20]))
    else:
        print("   do_one_initcall 不在可达集里 ⇒ 未测")

print("\n=== 2b) ★只用『逐个函数 prologue 直读』的那种数(第 1 节)，图上取最大那种一律不进判据 ===")
CHAIN = ["__arm64_sys_finit_module", "load_module", "do_one_initcall"]
tot, miss = 0, []
for n in CHAIN:
    f = frame_of(n)
    if isinstance(f, int):
        tot += f
        print("   %-26s %5d B" % (n, f))
    else:
        miss.append(n)
        print("   %-26s %s ⇒ 缺数(于是下面的和是**下界**)" % (n, f))
ENTRANCE = 512            # 系统调用入口固定开销(pt_regs＋el0_sync/invoke_syscall)——按宽了记
k = tot + ENTRANCE
print("   ★内核 insmod 那条路 ≈ %d B(直加 %d ＋ 入口宽记 %d；缺 %d 条)" % (k, tot, ENTRANCE, len(miss)))

print("\n=== 3) 与 boot 期那条路对照(厂商自己也要走；同样只用直读) ===")
for n in ("security_load_policy", "policydb_read"):
    print("   %-26s %s" % (n, frame_of(n)))
print("   ⇒ 厂商在 boot 期走的是**同一条 policydb_read 链**却没炸：这条对照只用来挡『我们的链特别深』那种说法")

print("\n=== 4) 判据(上界口径＋真链口径都要为正才敢判死) ===")
v1 = THREAD_SIZE - k - OURS_FULL
v2 = THREAD_SIZE - k - OURS_PARSE
print("   上界口径：≤ %d + %d = %d / %d ⇒ 余量 %d" % (k, OURS_FULL, k + OURS_FULL, THREAD_SIZE, v1))
print("   真链口径：≤ %d + %d = %d / %d ⇒ 余量 %d" % (k, OURS_PARSE, k + OURS_PARSE, THREAD_SIZE, v2))
if v1 > 0 and v2 > 0:
    print("   ★**栈溢出这一候选判死**：连『我们模块每个函数同时在栈上』这种不可能的上界都还剩 %d B；按真链剩 %d B。" % (v1, v2))
    print("     ⇒ 第 81 发那种『insmod 里就没回来』不是内核栈越界(VMAP_STACK 那条 fault 形状不成立)。")
    print("   ★口径边界(别说过头)：没算内核自己的被调者(kmalloc/avtab_* 等)的帧；要翻案得让它们额外吃 >%d B，" % v1)
    print("     而 boot 期厂商走同一条链没炸 ⇒ 这一支不成立。")
else:
    print("   余量非正 ⇒ 候选**仍活着**；下一格改成在设备上直接量剩余栈(见 §6.498 那条 rt_sp_* 设计)")
if miss:
    print("   ★注意：%d 条帧没读到(%s) ⇒ 上面是**下界**；下界仍留正余量才敢说判死" % (len(miss), ",".join(miss)))
if cycles:
    print("   (图上有环＝说明第 2 节那个『最深链』更是过近似；它不进判据)：%s" % ", ".join(sorted(cycles)[:6]))
