# -*- coding: utf-8 -*-
"""按截图像素找控件中心 —— uiautomator 在本机常 Aborted, dumpsys 的 bounds 又是相对父节点的。
用法: python findrow.py <png> <x0> <x1>   (在 x0..x1 这条竖带里找与背景明显不同的行块)"""
import sys
from PIL import Image

im = Image.open(sys.argv[1]).convert('RGB')
W, H = im.size
x0, x1 = int(sys.argv[2]), int(sys.argv[3])
px = im.load()


def bg(y):                      # 卡片内部的左边缘当背景(标题文字从更右边才开始)
    return px[70, y]


rows = []
run = -1
for y in range(0, H):
    hit = 0
    for x in range(x0, x1, 4):
        r, g, b = px[x, y]
        br, bgg, bb = bg(y)
        if abs(r - br) + abs(g - bgg) + abs(b - bb) > 90:
            hit += 1
    on = hit >= 3
    if on and run < 0:
        run = y
    elif not on and run >= 0:
        if y - run > 18:
            rows.append((run, y - 1, (run + y) // 2))
        run = -1
print('image %dx%d  竖带 x=%d..%d  找到 %d 块' % (W, H, x0, x1, len(rows)))
for i, (a, b, c) in enumerate(rows):
    print('块%d  y=%d..%d 中心=%d' % (i + 1, a, b, c))
