# -*- coding: utf-8 -*-
"""看 vivo 的安装确认弹窗长什么样: 从 uiautomator dump 里列出所有**可点击**节点的 text + 中心坐标。
用法: python suw_apk/ui_scan.py cm57/suw_ui_*.xml
"""
import io, re, sys

for f in sys.argv[1:]:
    try:
        s = io.open(f, encoding='utf-8', errors='replace').read()
    except Exception as e:
        print(f, 'READ-FAIL', e)
        continue
    wins = sorted(set(re.findall(r'package="([^"]+)"', s)))
    rows = []
    for m in re.finditer(r'<node[^>]*>', s):
        t = m.group(0)
        tx = re.search(r'text="([^"]*)"', t)
        cl = re.search(r'clickable="(\w+)"', t)
        bd = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', t)
        if not (tx and bd and cl and cl.group(1) == 'true'):
            continue
        txt = tx.group(1).strip()
        if not txt:
            continue
        x = (int(bd.group(1)) + int(bd.group(3))) // 2
        y = (int(bd.group(2)) + int(bd.group(4))) // 2
        rows.append((txt, x, y))
    print('== %s  窗口包名=%s  可点击文本=%d 个' % (f, wins[:4], len(rows)))
    for txt, x, y in rows[:12]:
        print('     [%4d,%4d] %s' % (x, y, txt[:40]))
