#!/usr/bin/env python3
# #231（0 枪）：在**真 ksud 二进制**里扫 KernelSU supercall 的 ioctl 命令字，与我们 ko 表里那批对表。
#   命令字形状(内核 _IOC)：dir(2b)<<30 | size(14b)<<16 | type(8b)<<8 | nr(8b)，type='K'=0x4b。
#   ★为什么这么扫而不是数字符串：字符串只能告我"源码里有这个名字"，不能告我"这个二进制真的会发这条命令字"；
#     而只看 movz 立即数会漏掉算出来的值。这里两者都不猜：把**所有**满足该形状的 32 位字按 nr 归堆，
#     再把"我们也有的 / 我们没有的"分开列，最后再判哪些是巧合(靠 nr 连号性与 size 合理性收口)。
import sys, struct, collections

path = sys.argv[1] if len(sys.argv) > 1 else r'kmod/_tmp_ksud_from_dev'
blob = open(path, 'rb').read()
print('FILE=%s BYTES=%d' % (path, len(blob)))

# 我们 ko 里已实现的命令字（kmod/ksu_uapi_supercall.h 现抄，dir/size/nr 三元组）
OURS = {  # nr: (dir, name)  dir: 0=_IO 1=_IOC_READ 2=_IOC_WRITE 3=READ|WRITE
    1: (0, 'GRANT_ROOT'), 2: (1, 'GET_INFO/LEGACY'), 3: (2, 'REPORT_EVENT'), 4: (3, 'SET_SEPOLICY'),
    5: (1, 'CHECK_SAFEMODE'), 6: (3, 'GET_ALLOW_LIST'), 7: (3, 'GET_DENY_LIST'),
    8: (3, 'UID_GRANTED_ROOT'), 9: (3, 'UID_SHOULD_UMOUNT'), 10: (1, 'GET_MANAGER_APPID'),
    11: (3, 'GET_APP_PROFILE'), 12: (2, 'SET_APP_PROFILE'), 13: (3, 'GET_FEATURE'),
    14: (2, 'SET_FEATURE'), 15: (2, 'GET_WRAPPER_FD'), 16: (3, 'MANAGE_MARK'),
    17: (2, 'NUKE_EXT4_SYSFS'), 18: (2, 'ADD_TRY_UMOUNT'), 19: (0, 'SET_INIT_PGRP'),
    20: (1, 'GET_SULOG_FD'), 21: (0, 'DISABLE_ESCAPE_TO_ROOT'),
}

hist = collections.Counter()
meta = {}
for off in range(0, len(blob) - 4):
    v = struct.unpack_from('<I', blob, off)[0]
    nr = v & 0xff
    typ = (v >> 8) & 0xff
    size = (v >> 16) & 0x3fff
    dirc = (v >> 30) & 0x3
    if typ != 0x4b or nr == 0 or nr > 63:
        continue
    if size > 0x400:                    # 真实 cmd 结构体没有大于 1 KiB 的
        continue
    hist[nr] += 1
    meta.setdefault(nr, set()).add((dirc, size))

print('候选命令字出现的 nr 直方图(type=0x4b, nr<=63, size<=1024)：')
for nr in sorted(hist):
    tag = '我们有: ' + OURS[nr][1] if nr in OURS else '★我们没有'
    kinds = ','.join('%s%d/%s%d' % ('DIR', d, 'SZ', s) for d, s in sorted(meta[nr])[:6])
    print('  nr=%-3d 命中=%-6d %s  [%s]' % (nr, hist[nr], tag, kinds))
print('总候选=%d  不重复 nr 数=%d' % (sum(hist.values()), len(hist)))
print('我们表里的 nr 覆盖：1..21（21 条定义，ko 的 handler 表按名注册）')
