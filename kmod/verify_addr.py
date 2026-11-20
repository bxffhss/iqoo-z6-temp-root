# -*- coding: utf-8 -*-
"""把模块打印的运行时地址变成**判据**：观测值 - slide 必须等于离线 kallsyms 的链接期地址。

用法:
  python kmod/verify_addr.py <slide(十六进制,可带0x)> <日志文件> [<embedded-kallsyms.txt>]
  # 日志就是 dmesg 抓下来的行，形如
  #   suwksyms: kallsyms_lookup_name(commit_creds) = 0xffffffe5c7xxxxxx

为什么要有这个脚本：只看"地址非零/看着像内核地址"是**假阳性**的老源头
(见 [[feedback-gpu-execution-oracles]] / [[feedback-probe-false-positives]])。
这里要求**多个符号给出同一个差值**，任何一个不匹配就整体判不通过。
"""
import io
import re
import sys

PAT = re.compile(r'(\w+)\)\s*=\s*0x([0-9a-fA-F]{6,16})')


def load_kallsyms(path):
    m = {}
    with io.open(path, encoding='utf-8', errors='replace') as f:
        for ln in f:
            p = ln.split()
            if len(p) >= 3 and len(p[0]) in (8, 16) and p[1] in ('t', 'T', 'w', 'W'):
                m.setdefault(p[2], int(p[0], 16))
    return m


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    slide = int(sys.argv[1], 16)
    log = sys.argv[2]
    ks = load_kallsyms(sys.argv[3] if len(sys.argv) > 3
                       else 'analysis/embedded-kallsyms.txt')
    rows = []
    with io.open(log, encoding='utf-8', errors='replace') as f:
        for ln in f:
            m = PAT.search(ln)
            if not m:
                continue
            name, obs = m.group(1), int(m.group(2), 16)
            if name in ('kallsyms_lookup_name',) and 'suwksyms' not in ln:
                pass
            rows.append((name, obs))

    if not rows:
        sys.exit('日志里没解析到任何 "xxx) = 0x...." 行 —— 检查抓取命令与 grep 关键字')

    diffs = {}
    print('%-34s %-20s %-20s %s' % ('符号', '观测(运行时)', '离线(链接期)', '差值'))
    bad = 0
    for name, obs in rows:
        link = ks.get(name)
        if link is None:
            print('%-34s 0x%016x  %-20s 离线表里没有' % (name, obs, '-')); bad += 1; continue
        d = obs - link
        diffs[name] = d
        flag = 'OK' if d == slide else '不等于 slide!'
        print('%-34s 0x%016x 0x%016x  0x%x  %s' % (name, obs, link, d, flag))
        if d != slide:
            bad += 1

    uniq = set(diffs.values())
    print('\nslide = 0x%x, 观测到的差值集合 = %s' % (slide, ['0x%x' % x for x in sorted(uniq)]))
    if bad == 0 and len(uniq) == 1:
        print('判定: 通过 —— %d 个符号全部落在同一个 slide 上，与离线 kallsyms 逐字节吻合' % len(rows))
    else:
        print('判定: 不通过 (%d 处不对/缺表)' % bad)
    sys.exit(0 if bad == 0 and len(uniq) == 1 else 1)


main()
