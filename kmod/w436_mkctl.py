# -*- coding: utf-8 -*-
"""w436_mkctl.py — 从**出货 kallsyms** 现算设备侧求解器要的正对照窗口表(slide_ctl.txt)。

为什么要有这个生成器：正对照函数的链接期地址与宽度是 #146 唯一能带进设备的"知识"，
手抄一次就会在未来某次换 SPL/换 ko 之后悄悄失效(地址变了但表没变 ⇒ 求解器只会 NOSLIDE，
或直接解出错的 slide 并把错的数交给 punch)。所以：
  · 函数名单 CTRL 与 TEXT/ETEXT/STEP **不在这份文件里重写**，是从 analysis/slide_pc.py 抠出来的
    ⇒ 单一来源；哪天 PC 侧换了判据函数，设备侧的表自动跟着变，两处不可能分叉。
  · 地址与宽度一律现读 kallsyms(就是打进包里那份)。

用法: python kmod/w436_mkctl.py <kallsyms.txt> <out_slide_ctl.txt>
      缺名按 PC 版同口径跳过并写进产物注释；剩不到 5 个窗口才不出文件。
"""
import io, re, sys

SOLVER = r'G:\项目\Windows管理\usb\临时root\analysis\slide_pc.py'
CAP = 0x700                                   # 与 slide_pc.py 里 min(下一符号-本符号, 0x700) 同口径


def consts():
    """把 slide_pc.py 的 TEXT/ETEXT/STEP/CTRL 抠出来——**不是**在本文件里再写一遍。"""
    txt = io.open(SOLVER, encoding='utf-8', errors='replace').read()
    c = {}
    for k in ('TEXT', 'ETEXT', 'STEP'):
        m = re.search(r'^%s = (0x[0-9a-fA-F]+)' % k, txt, re.M)
        if not m:
            sys.exit('从 slide_pc.py 里找不到 %s ⇒ 口径变了，先看那份文件' % k)
        c[k] = int(m.group(1), 16)
    m = re.search(r'^CTRL = \[(.*?)\]', txt, re.M | re.S)
    if not m:
        sys.exit('从 slide_pc.py 里找不到 CTRL 列表')
    names = re.findall(r"'([^']+)'", m.group(1))
    if len(names) < 3:
        sys.exit('CTRL 只抠到 %d 个名字 ⇒ 不像真的' % len(names))
    return c, names


def main():
    ks, out = sys.argv[1], sys.argv[2]
    c, names = consts()
    syms = []
    for line in io.open(ks, encoding='utf-8', errors='replace'):
        p = line.split()
        if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
            syms.append((int(p[0], 16), ' '.join(p[2:])))
    syms.sort()
    idx = {}
    for i, (a, n) in enumerate(syms):
        idx.setdefault(n, i)                 # 同名取第一个(与 PC 版一致：它也是 break 第一条)
    rows, miss = [], []
    for nm in names:
        i = idx.get(nm)
        if i is None or i + 1 >= len(syms):
            miss.append(nm); continue
        ln = min(syms[i + 1][0] - syms[i][0], CAP)
        if ln <= 0:
            miss.append('%s(宽度=%d)' % (nm, ln)); continue
        rows.append((syms[i][0], ln, nm))
    if miss:
        # ★缺名**不判死**，因为 PC 版也不判死：slide_pc.py 是 `for nm in CTRL: 找到才 append`，
        #   这份出货 kallsyms 里就没有 `user_path_at`(被内联了)，所以 PC 那侧一直只跑 9 个窗口。
        #   生成器必须跟着同一口径，否则会出现"设备侧拒绝出表、PC 侧照样解得出"的分叉。
        #   但缺名要**写进产物**，别只打在 stdout(那行会被翻过去)。
        if len(rows) < 5:
            sys.exit('正对照只剩 %d 个窗口(缺失：%s)⇒ 太少，不出文件' % (len(rows), ', '.join(miss)))
    tot = sum(r[1] for r in rows)
    with io.open(out, 'w', encoding='utf-8', newline='\n') as f:      # ★LF：设备不吃 CRLF
        # ★step 一律写成**十进制**并叫 `step_dec`：真机上第一次标定跑就是被这个坑到的——
        #   表头写 `step=200000`(hex) 而 awk 把 -v 的值按十进制解析 ⇒ 步长成了 200000(B10)=0x30d40，
        #   扫出 69 档非对齐候选。它没解出错 slide(正对照命中=1 ⇒ 自己 NOSLIDE 收场)，
        #   但这种"单位藏在名字里"的字段，名字里就得带单位。地址仍写 16 位 hex(求解器自己按 hex 读)。
        f.write('# CONSTS link_text=%016x link_etext=%016x step_dec=%d\n'
                % (c['TEXT'], c['ETEXT'], c['STEP']))
        f.write('# 由 kmod/w436_mkctl.py 现算(名单与常量都取自 analysis/slide_pc.py)，宽度=min(下一符号-本符号,%#x)\n' % CAP)
        if miss:
            f.write('# 缺名(与 PC 版同口径跳过，不算错)：%s\n' % ', '.join(miss))
        for a, ln, nm in rows:
            f.write('%016x %d %s\n' % (a, ln, nm))
    print('WINS 条数=%d 合计宽度=%d 字节 %#x 名单=%s' % (len(rows), tot, tot, ','.join(names)))
    if miss:
        print('SKIP 缺名=%s' % ','.join(miss))
    print('CONSTS link_text=%x link_etext=%x step=%x' % (c['TEXT'], c['ETEXT'], c['STEP']))


if len(sys.argv) != 3:
    sys.exit('用法: python kmod/w436_mkctl.py <kallsyms.txt> <out_slide_ctl.txt>')
main()
