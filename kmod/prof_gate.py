#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""prof_gate.py —— Profile 页的**身份闸**：从树里量出那个 checkable 开关，并判"这一页是不是我们要授权的那个 uid"。

为什么改版(2026-10-21 第 35 发，一手件 kmod/w103_evidence/w462_prof.xml)：
  旧闸要求树里**同时**出现"整包名"和"UID <n>"。但一个被 35 个应用共用的 uid，官方那一页显示的
  **代表包不是我们要的包**：真树里写的是 `com.galMag.dataViewer` + `包含 35 个应用` + `UID 10667`，
  整棵树里**没有 `com.termux` 这个串** ⇒ 旧闸在**正确的页面上也必然判不中**(它拒得保守，但也把好页当坏页)。
  ⇒ 承重身份改成：**`App Profile`(这确实是 Profile 页) ∧ `UID <n>`(这确实是那个 uid)**。
     选 UID 不是将就——内核名单本身就是按 uid 记的，包名只是这一页的显示产物。
     包名核对**降级为读数**(中/不中都打印，不中还打印这一页自己的代表包)，绝不再当闸门。

用法：prof_gate.py <xml> <期望包名> <期望uid> <输出文件>
输出文件四个字段：'<cx> <cy> <checked> <ident>'，ident=1 才允许点开关；**不写行尾换行**(例 111：
  Windows 文本模式会把补的 '\n' 写成 '\r\n' ⇒ 调用方读出来是 "1\r" 对不上)。
★拒点/没读到 ⇒ 先删输出文件，绝不让上一轮的坐标留在原地。
"""
import io
import os
import re
import sys

NODE = re.compile(r'<node[^>]*')
# ★段里必须容大写：这一页真实的代表包就是 `com.galMag.dataViewer`(驼峰)，只写 [a-z0-9_] 会让
#   "代表包"读数跳到后面某条全小写的行上去(第 35 发那份树里就跳到了 com.tencent.baiye)。
PKGSHAPE = re.compile(r'^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+$')


def attr(t, k):
    m = re.search(r'%s="([^"]*)"' % k, t)
    return m.group(1) if m else ''


def main():
    p, pkg, uid, outf = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    if os.path.exists(outf):
        os.remove(outf)
    if not (os.path.exists(p) and os.path.getsize(p)):
        print('  [x] %s 不存在或 0 字节 ⇒ dump 这一腿根本没成(别拿旧树当现状)' % p)
        return 3
    s = io.open(p, encoding='utf-8', errors='replace').read()
    texts = [m.group(1) for m in re.finditer(r'text="([^"]*)"', s)]
    shown = [t for t in texts if t]
    print('  这一页的文本(前 8 条): %s' % shown[:8])
    sw = [m.group(0) for m in NODE.finditer(s) if 'checkable="true"' in m.group(0)]
    ok_ap = any('App Profile' in t for t in shown)
    ok_uid = any(('UID ' + uid) in t for t in shown)
    ok_pkg = any(pkg in t for t in shown)
    rep = [t for t in shown if PKGSHAPE.match(t.strip())]
    print('  页身份 App Profile: %s / UID %s: %s / 包名 %s: %s%s'
          % ('中' if ok_ap else '不中', uid, '中' if ok_uid else '不中', pkg,
             '中(加分)' if ok_pkg else '不中(只当读数)',
             '' if ok_pkg or not rep else '｜这一页自己的代表包=%s' % rep[0]))
    if not sw:
        print('  没找到 checkable 开关 ⇒ 这一页不是 Profile 页(或还没渲染出来)')
        return 4
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', sw[0])
    if not b:
        print('  开关节点没有 bounds ⇒ 不点')
        return 5
    g = [int(x) for x in b.groups()]
    cx, cy = (g[0] + g[2]) // 2, (g[1] + g[3]) // 2
    chk = attr(sw[0], 'checked')
    ident = 1 if (ok_ap and ok_uid) else 0
    print('  开关 bounds=%s -> (%d,%d) 当前 checked=%s ⇒ 身份闸=%s'
          % (g, cx, cy, chk, '通过' if ident else '不通过'))
    if not ident:
        print('  [!] 缺的那半：' + '、'.join(x for x, ok in (('App Profile', ok_ap), ('UID ' + uid, ok_uid)) if not ok))
        return 6
    io.open(outf, 'w', encoding='utf-8', newline='').write('%d %d %s %d' % (cx, cy, chk, ident))
    return 0


if __name__ == '__main__':
    sys.exit(main())
