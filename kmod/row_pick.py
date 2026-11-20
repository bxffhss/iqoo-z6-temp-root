#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""row_pick.py v2 —— 从"超级用户列表(搜索态)"那棵 uiautomator 树里找**该点的那张卡**的可点中心。

为什么改版(2026-10-21 第 35 发，一手件在 kmod/w103_evidence/w462_srctree.xml)：
  v1 拿到的是"包名文本节点自己的中心"，但那一行在树里 **clickable=false** —— 过滤后的列表里
  唯一可点的容器只有那张 **组卡** `[36,318][1044,510]`(标签 `ZeroTermux / Termux user / 包含 35 个应用 / UMOUNT`，
  里面**没有包名串**)。v1 算出的 (383,849) 落在可点容器之外 ⇒ 连点四下全打在空处。
  ★这一条的硬证人：`ug_srch.xml` 与当时那份"Profile 页 dump" `ug_prof.xml` **md5 完全相同**
    (`975cc5b58cdb6e40280e1be752384001`)⇒ 页面根本没动。

v2 的规矩(不写死坐标、不写死 y)：
  卡片 = clickable="true" ∧ 类名不是 EditText/ImageView/TextView(那是字段与图标本身)
         ∧ 几何上完整包住 **≥2 条**有标签的后代(nav 那三个可点 View 各只包 1 条 ⇒ 自动出局)
         ∧ **最小**(能包住另一张卡的容器不算卡，那是整屏滚动容器)
  命中 = 卡内任一标签(不区分大小写)含**过滤词**，或含**整包名**；必须**恰好一张**
  ⇒ 0 张/多于 1 张都拒点。**拒点时绝不写输出文件**(例 113：残留坐标被下一轮 read 走是真的发生过的事)。

用法：row_pick.py <xml> <期望包名> <输出文件> [过滤词]
  过滤词不给时退回"期望包名按点切出的最长段"(与 ui_grant.sh 的 pick_term 同一个意思)。
退出码：0=唯一命中并写了坐标；3=有卡但没有一张含过滤词；4=树里一张卡都没有(多半页面没渲染)；
        5=含过滤词的卡多于一张 ⇒ 形状有歧义，不点。
★规矩照旧(例 70)：坐标**只写文件**，stdout 只给人看的解释；调用方要校验形状再用。
"""
import io
import os
import re
import sys

NODE = re.compile(r'<node\b[^>]*')
BND = re.compile(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')
LEAFY = ('EditText', 'ImageView', 'TextView', 'ImageButton')


def attr(t, k):
    m = re.search(r'%s="([^"]*)"' % k, t)
    return m.group(1) if m else ''


def parse(path):
    s = io.open(path, encoding='utf-8', errors='replace').read()
    out = []
    for m in NODE.finditer(s):
        t = m.group(0)
        b = BND.search(t)
        if not b:
            continue
        g = [int(x) for x in b.groups()]
        out.append({'lab': (attr(t, 'text') or attr(t, 'content-desc')).strip(),
                    'cls': attr(t, 'class'), 'clk': attr(t, 'clickable'), 'g': g})
    return out


def wraps(outer, inner):
    return (outer[0] <= inner[0] and inner[2] <= outer[2]
            and outer[1] <= inner[1] and inner[3] <= outer[3])


def same(a, b):
    return list(a) == list(b)


def cards(nodes):
    labs = [n['g'] for n in nodes if n['lab']]
    cs = []
    for n in nodes:
        if n['clk'] != 'true':
            continue
        if any(k in n['cls'] for k in LEAFY):
            continue
        if sum(1 for g in labs if wraps(n['g'], g)) < 2:
            continue
        cs.append(n['g'])
    # 只留最小的：能完整包住"另一张也是卡的容器"的那个是滚动容器，不是可点的行
    return [g for g in cs if not any(wraps(g, o) and not same(g, o) for o in cs)]


def main():
    xml, want, outf = sys.argv[1], sys.argv[2], sys.argv[3]
    term = sys.argv[4].lower() if len(sys.argv) > 4 and sys.argv[4] else ''
    if not term:
        segs = [re.sub(r'[^a-z0-9]', '', w) for w in re.split(r'[._]', want.lower())]
        term = max(segs, key=len) if segs else ''
        print('  [推导] 没给过滤词 ⇒ 用 %s 的最长段 [%s]' % (want, term))
    if not (os.path.exists(xml) and os.path.getsize(xml)):
        print('  [r4] %s 不存在或 0 字节 ⇒ dump 这一腿根本没成(别拿旧树当现状)' % xml)
        if os.path.exists(outf):
            os.remove(outf)
        return 4
    if os.path.exists(outf):
        os.remove(outf)                                # ★残留坐标绝不能被下一轮 read 拿去点
    nodes = parse(xml)
    cs = cards(nodes)
    print('  可点卡片 %d 张：%s' % (len(cs), ', '.join('[%d,%d][%d,%d]' % tuple(c) for c in cs)))
    if not cs:
        print('  [r4] 这棵树里没有"可点卡片"⇒ 页面可能还在刷新，**不点**')
        return 4
    hits = []
    for g in cs:
        ls = [n['lab'] for n in nodes if n['lab'] and wraps(g, n['g'])]
        low = ' '.join(ls).lower()
        if (term and term in low) or want.lower() in low:
            hits.append((g, ls))
    print('  这屏卡片一览：')
    for g in cs:
        ls = [n['lab'] for n in nodes if n['lab'] and wraps(g, n['g'])]
        print('     [%d,%d][%d,%d] 标签=%s' % (g[0], g[1], g[2], g[3], ls))
    if len(hits) > 1:
        print('  [r5] 含 [%s] 的卡有 %d 张 ⇒ **形状有歧义，不点**（先看上面那一览，是谁都在）' % (term, len(hits)))
        return 5
    if not hits:
        print('  [r3] 没有一张卡含 [%s]（卡内标签见上面一览）⇒ 这一发不该点卡片' % term)
        return 3
    g, ls = hits[0]
    cx, cy = (g[0] + g[2]) // 2, (g[1] + g[3]) // 2
    io.open(outf, 'w', encoding='utf-8', newline='').write('%d %d' % (cx, cy))
    print('  [r0] 唯一命中：卡 [%d,%d][%d,%d] 中心=(%d,%d) 标签=%s' % (g[0], g[1], g[2], g[3], cx, cy, ls))
    return 0


if __name__ == '__main__':
    sys.exit(main())
