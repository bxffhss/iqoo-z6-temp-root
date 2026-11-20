#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""dump_obj.py —— 打印镜像里某个静态对象的 qword, 并把 .rela 的"链接期值 + 目标符号名"附上。
用途: 定结构体布局(task_struct/cred/rt_mutex/ctl_table…), 比靠猜偏移可靠得多。
用法: python dump_obj.py <符号|地址> [长度=0x80] [符号表基址=自身]
"""
import io, re, struct, bisect, sys

BASE = 0xffffffc010080000
AN = r'G:\项目\Windows管理\usb\临时root\analysis'
data = io.open(AN + r'\kernel_dev_g2a88cd145def.bin', 'rb').read()
KS = AN + r'\kallsyms_g2a88cd145def.txt'
syms = []
for l in io.open(KS, encoding='utf-8', errors='replace'):
    p = l.split()
    if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
        syms.append((int(p[0], 16), p[1], ' '.join(p[2:])))
syms.sort()
addrs = [a for a, _, _ in syms]
RELA = None


def name_of(a):
    i = bisect.bisect_right(addrs, a) - 1
    if i < 0:
        return None
    return '%s(%s)+0x%x' % (syms[i][2], syms[i][1], a - syms[i][0])


def load_rela():
    global RELA
    if RELA is not None:
        return RELA
    RELA = {}
    for off in range(0, len(data) - 0x18, 8):
        if struct.unpack_from('<Q', data, off + 8)[0] == 1027:      # R_AARCH64_RELATIVE
            RELA[struct.unpack_from('<Q', data, off)[0]] = \
                struct.unpack_from('<Q', data, off + 16)[0]
    return RELA


def addr_of(n):
    if n.startswith('0x'):
        return int(n, 16)
    for a, t, nm in syms:
        if nm == n:
            return a
    raise SystemExit('找不到符号 ' + n)


def dump(start, ln):
    R = load_rela()
    print('%-8s %-20s %-20s %s' % ('off', '静态qword', 'rela加数', '加数指向'))
    for o in range(0, ln, 8):
        a = start + o
        v = struct.unpack_from('<Q', data, a - BASE)[0]
        r = R.get(a)
        print('+0x%-6x %016x       %s   %s' % (
            o, v, ('%016x' % r) if r is not None else '-',
            (name_of(r) or '') if r else ''))


if __name__ == '__main__':
    st = addr_of(sys.argv[1])
    dump(st, int(sys.argv[2], 0) if len(sys.argv) > 2 else 0x80)
