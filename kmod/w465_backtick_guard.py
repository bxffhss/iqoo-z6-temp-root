#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""w465_backtick_guard.py —— 静态扫"反引号雷"：bash 里 echo "...cmd..." 这种双引号串会**真的执行**那条命令。

为什么要有它(2026-10-22 00:5x，例 76 在这个仓里已经是第四次)：我今晚改 `go.sh` 的一句提示文案时，
在双引号的 echo 里用反引号包住了一条命令 —— 文案改动当场变成行为改动(那行一打印就重启设备)。
`bash -n` 抓不到它(语法完全合法)，只有内容扫描能抓。

判据(保守)：只看 echo/printf **那对双引号内部**有没有反引号。
  行尾注释里的、单引号参数里的反引号**都不执行** ⇒ 不报；线级粗扫今天实测 4 条里 2 条是这种假红，
  天天响的闸等于没有闸(例 84：判据红有三种世界)。
用法：python kmod/w465_backtick_guard.py [--self]
退出码：0=干净；1=有命中(逐条打 file:line + 原文)；2=自检红或要扫的路径不存在。
"""
import io
import os
import re
import sys

BT = chr(96)                      # 反引号：源码里不写字面量，免得这道守卫撞上自己的扫描(例 140)
ECHODQ = re.compile(r'\b(?:echo|printf)\s+(?:-n\s+)?"((?:[^"\\]|\\.)*)"')


def scan_text(text):
    """返回 [(行号, 该行原文)] —— echo/printf 的双引号串里有反引号的行。"""
    out = []
    for n, line in enumerate(text.split('\n'), 1):
        st = line.strip()
        if not st or st.startswith('#') or st.startswith('//'):
            continue
        if BT not in line:
            continue
        for m in ECHODQ.finditer(line):
            if BT in m.group(1):
                out.append((n, st))
                break
    return out


def scan_files(paths):
    hits = []
    for p in paths:
        if not os.path.exists(p):
            print('  [x] 要扫的路径不存在：%s ⇒ 这条守卫没在扫你以为它在扫的东西' % p)
            sys.exit(2)
        text = io.open(p, encoding='utf-8', errors='replace').read()
        hits += [(p, n, s) for n, s in scan_text(text)]
    return hits


def repo_sh_files():
    fs = []
    for d in ('kmod', 'kmod/_tmp_selftest_rdst', 'cm57'):
        if os.path.isdir(d):
            for f in sorted(os.listdir(d)):
                if f.endswith('.sh'):
                    fs.append((d + '/' + f).replace('\\', '/'))
    return fs


def selftest():
    ok = True
    n = 0
    # ① 正例必须报(不报＝这道守卫没牙)
    h = scan_text('echo "  建议手动 ' + BT + 'adb reboot' + BT + ' 清状态"' + '\n')
    n += 1
    ok = ok and len(h) == 1
    print('  [%s] ①双引号 echo 里的反引号被报出来(实得 %d 条，须 1)' % ('OK' if len(h) == 1 else 'x', len(h)))
    # ② 负例：单引号里的不执行 ⇒ 不许报(报了就是天天假红)
    h = scan_text("echo '  建议手动 " + BT + "adb reboot" + BT + " 清状态'" + '\n')
    n += 1
    ok = ok and not h
    print('  [%s] ②单引号 echo 里的反引号**不报**(实得 %d 条)' % ('OK' if not h else 'x', len(h)))
    # ③ 行尾注释里的反引号不许报(代码部分本身是干净的)
    h = scan_text('echo "${r}"; }   # 说明：' + BT + 'tr -dc 0-9' + BT + ' 会挤掉小数点' + '\n')
    n += 1
    ok = ok and not h
    print('  [%s] ③行尾注释里的反引号不报(实得 %d 条)' % ('OK' if not h else 'x', len(h)))
    # ④ 整行注释不许报(自家说明文字，例 140)
    h = scan_text('# 说明：双引号里 ' + BT + 'cmd' + BT + ' 会执行' + '\n')
    n += 1
    ok = ok and not h
    print('  [%s] ④注释行不报(实得 %d 条)' % ('OK' if not h else 'x', len(h)))
    # ⑤ 双引号串里混着单引号又有反引号 ⇒ 要报(真会执行)
    h = scan_text('echo "外层 ' + BT + "内层'引号" + BT + ' 结束"' + '\n')
    n += 1
    ok = ok and len(h) == 1
    print('  [%s] ⑤双引号里混单引号的反引号仍报(实得 %d 条)' % ('OK' if len(h) == 1 else 'x', len(h)))
    print('=== w465 自检 %s(共 %d 项，条数由 n 自数) ===' % ('PASS' if ok else 'FAIL', n))
    return 0 if ok else 2


def main():
    if '--self' in sys.argv:
        return selftest()
    files = sys.argv[1:] or repo_sh_files()
    hits = scan_files(files)
    print('  扫了 %d 个 shell 件(只看 echo/printf 双引号内部；探测符=%s)' % (len(files), BT))
    if hits:
        for p, n, s in hits:
            print('  [雷] %s:%d  %s' % (p, n, s[:150]))
        print('=== 命中 %d 条 ⇒ 这些行一执行就会跑掉那条命令(文案改动＝行为改动) ===' % len(hits))
        return 1
    print('=== 对照 OK：0 条 ===')
    return 0


if __name__ == '__main__':
    sys.exit(main())
