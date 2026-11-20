# -*- coding: utf-8 -*-
"""按**子串**在 uiautomator dump 里找可点节点并输出中心坐标; 顺带能读 checked 状态。
用法: python tapfind.py <ui.xml> <子串> [--checked]
★ 每次 tap 前都要重新 dump: 状态 TextView 变长会把整排按钮推下去(实测 1433 -> 1997)。
"""
import io, re, sys

s = io.open(sys.argv[1], encoding='utf-8', errors='replace').read()
want = sys.argv[2]
need_checked = '--checked' in sys.argv
for m in re.finditer(r'<node\b[^>]*>', s):
    t = m.group(0)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', t)
    if not b:
        continue
    def a(k):
        r = re.search(k + r'="([^"]*)"', t)
        return r.group(1) if r else ''
    lab = (a('text') or a('content-desc')).replace('\n', ' ')
    if want not in lab or a('clickable') != 'true':
        continue
    if need_checked:
        print('CHECKED=' + a('checked'))
        raise SystemExit(0)
    x1, y1, x2, y2 = map(int, b.groups())
    print('%d %d' % ((x1 + x2) // 2, (y1 + y2) // 2))
    raise SystemExit(0)
print('NOTFOUND')
