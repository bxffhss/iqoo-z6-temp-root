#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""solve_slide.py —— 由"shell 自采样 perf 的内核 IP" + 设备同构建 kallsyms 解出本次开机的 KASLR slide。

流程(两步):
  1) 采集:  adb shell /data/local/tmp/perfips 3 > ips.txt      (源码 C:/qemu_test/perfips.c)
  2) 解算:  python solve_slide.py [<符号表> <ips> <kernel.bin>]
原理: 核心 text 内符号间隔平均只有几百字节 ⇒ "所有样本减去同一个 s 后都落在某个符号区间内"
      这个约束极强(随机 s 的通过率约 1e-4), 因此不需要假设 slide 是 2MB 对齐也能唯一确定;
      再用两条独立校验: ① __bss_start<selinux_state<__bss_stop;  ② 簇内落到 text 的比例。
输出: 每个关键符号的 static/runtime 地址, 并写 analysis/slide_now.txt。
"""
import io, re, sys, bisect
from collections import Counter

KS  = sys.argv[1] if len(sys.argv) > 1 else r'G:\项目\Windows管理\usb\临时root\analysis\kallsyms_g2a88cd145def.txt'
IPS = sys.argv[2] if len(sys.argv) > 2 else r'C:\qemu_test\ips.txt'
OUT = r'G:\项目\Windows管理\usb\临时root\analysis\slide_now.txt'
T0, T1 = 0xffffffc010081000, 0xffffffc0115a0000        # [_stext, _etext)

syms = []
for line in io.open(KS, encoding='utf-8', errors='replace'):
    p = line.split()
    if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
        syms.append((int(p[0], 16), p[2]))
syms.sort()
txt = [a for a, n in syms if T0 <= a < T1]
obs = sorted(int(l.split()[1], 16) for l in io.open(IPS, encoding='utf-8') if l.startswith('k '))
if len(obs) < 50:
    raise SystemExit("样本太少(%d): 先跑 perfips 采 IP" % len(obs))

cl = [[obs[0]]]
for a in obs[1:]:
    (cl.append([a]) if a - cl[-1][-1] > (64 << 20) else cl[-1].append(a))
C = max(cl, key=len)
a0, probe = C[0], C[1:41]
best = (0, None)
for y in txt:
    if y > a0: break
    s = a0 - y
    ok = 0
    for a in probe:
        v = a - s
        if v < T0 or v >= T1: continue
        i = bisect.bisect_right(txt, v) - 1
        if i + 1 >= len(txt) or v < txt[i + 1]: ok += 1
    if ok > best[0]: best = (ok, s)
hit, s = best
if hit < len(probe) * 0.85:
    raise SystemExit("未找到一致 slide (probe %d/%d) ⇒ 检查符号表是否与设备构建一致" % (hit, len(probe)))

tot = sum(1 for a in C if T0 <= a - s < T1)
def rt(nm, off=0):
    m = [a for a, n in syms if n == nm]
    return m[0] + s + off if m else None
bs, be, ss = rt('__bss_start'), rt('__bss_stop'), rt('selinux_state')
print("slide = 0x%x  (%d MB)" % (s, s >> 20))
print("一致性: 簇内 %d/%d 落到 text; probe %d/%d; BSS 包含 selinux_state: %s"
      % (tot, len(C), hit, len(probe), bool(bs and be and ss and bs < ss < be)))
targets = ['_stext', '_etext', '__bss_start', '__bss_stop', 'selinux_state', 'security_hook_heads',
           'commit_creds', 'prepare_kernel_cred', 'init_cred', 'init_task', 'avc_has_perm',
           'remove_waiter', 'binder_free_transaction', 'binder_send_failed_reply',
           'binder_thread_release', 'binder_release_work', 'acc_fops', 'ashmem_fops', 'i2cdev_ioctl']
lines = ["slide=0x%x" % s]
for nm in targets:
    m = [a for a, n in syms if n == nm]
    if m:
        lines.append("%-26s static=0x%016x runtime=0x%016x" % (nm, m[0], m[0] + s))
        print(lines[-1])
enf = rt('selinux_state', 1)
lines.append("★ enforce (=selinux_state+1)  runtime=0x%016x" % enf)
print(lines[-1])
io.open(OUT, 'w', encoding='utf-8').write("\n".join(lines) + "\n")
print("已写", OUT, "（注意: slide 每次开机都变, 动手前必须重采）")
