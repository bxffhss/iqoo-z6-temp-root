# -*- coding: utf-8 -*-
"""pctl.py — 纯采样的正对照检查(不 punch, 不重启)。

让设备只跑 getppid() 死循环 → perfips 采样 → 对每个候选 slide 用 kallsyms 把样本
解析成符号, 打印 top 名字 + 落在"入口区/getppid/el0_svc_common"里的个数。
正确 slide 的样子是确定的: 样本必须集中在 syscall 入口/出口汇编 + __arm64_sys_getppid。
"""
import bisect, io, os, re, subprocess, sys, time

BASE = r'G:\项目\Windows管理\usb\临时root'
ADB = r'C:\adb\platform-tools\adb.exe'
DEV = '<DEVICE_SERIAL>'
AN = os.path.join(BASE, 'analysis')
KS = os.path.join(AN, 'kallsyms_g2a88cd145def.txt')
CL = (r'J:\Users\Administrator\AppData\Local\Android\Sdk\ndk\27.3.13750724'
      r'\toolchains\llvm\prebuilt\windows-x86_64\bin\aarch64-linux-android35-clang.cmd')
GETPPID = 0xffffffc0102ff034
ENTRY = 0xffffffc0100840c0
SVC_COMMON = 0xffffffc0102c63b0
try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass


def sh(args, **kw):
    kw.setdefault('capture_output', True)
    kw.setdefault('text', True)
    kw.setdefault('encoding', 'utf-8')
    kw.setdefault('errors', 'replace')
    return subprocess.run(args, **kw)


syms = []
for line in io.open(KS, encoding='utf-8', errors='replace'):
    p = line.split()
    if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
        syms.append((int(p[0], 16), ' '.join(p[2:])))
syms.sort()
ADDRS = [a for a, n in syms]


def name_of(a):
    i = bisect.bisect_right(ADDRS, a) - 1
    if i < 0:
        return None
    return syms[i][1] + ('+0x%x' % (a - ADDRS[i]) if i + 1 < len(ADDRS) else '')


def main():
    r = sh([CL, '-O2', '-g0', '-fPIE', '-pie', '-Wall',
            os.path.join(BASE, 'cm57', 'sp.c'), '-o', os.path.join(BASE, 'cm57', 'spbin')])
    if r.returncode:
        print(r.stderr[-1500:]); return
    sh([ADB, '-s', DEV, 'push', os.path.join(BASE, 'cm57', 'spbin'), '/data/local/tmp/sp'])
    sh([ADB, '-s', DEV, 'shell', 'chmod', '755', '/data/local/tmp/sp'])
    chk = sh([ADB, '-s', DEV, 'shell', '/data/local/tmp/sp', '173', '1'])
    print('sp 自检 rc=%s out=%r' % (chk.returncode, (chk.stdout or '')[-80:]), flush=True)

    # 正对照必须**压过背景噪声**: 一个 getppid 循环在 8 核 Android 上会被
    # 系统后台(path_openat/vsnprintf/scheduler)完全淹没(实测: 入口区 0 命中)。
    # ⇒ 每个核都开一个 sp, 让 syscall 入口/出口汇编成为全机最热的代码。
    nsp = 10
    procs = [subprocess.Popen([ADB, '-s', DEV, 'shell', '/data/local/tmp/sp', '173', '60'],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
             for _ in range(nsp)]
    time.sleep(3)
    p = sh([ADB, '-s', DEV, 'shell', '/data/local/tmp/perfips', '25'], timeout=200)
    sh([ADB, '-s', DEV, 'shell', 'killall', 'sp'], timeout=20)
    for pr in procs:
        pr.wait(timeout=30)
    ips = sorted({int(q[1], 16) for l in p.stdout.splitlines()
                  for q in [l.split()] if len(q) == 2 and q[0] == 'k'})
    print('样本 %d 个, 跨度 %#x' % (len(ips), ips[-1] - ips[0]), flush=True)
    # 按 4MB 间隙切簇, 取最大簇 + 与之相距 <21.1MB 的簇(滤掉模块/vmalloc 噪声)
    TEXT_LEN = 0x1520000
    cl, cur = [], [ips[0]]
    for a, b in zip(ips, ips[1:]):
        if b - a > 0x400000:
            cl.append(cur); cur = [b]
        else:
            cur.append(b)
    cl.append(cur)
    big = max(cl, key=len)
    keep = sorted(a for c in cl for a in c if c is big or (c[0] - big[0]) < TEXT_LEN)
    print('  簇 %s → 留 %d' % ([len(c) for c in cl], len(keep)), flush=True)
    ips = keep
    f = r'C:\qemu_test\ips_pctl.txt'
    io.open(f, 'w', encoding='utf-8').write('\n'.join('k %x' % a for a in ips) + '\n')
    out = sh([sys.executable, os.path.join(AN, 'slide.py'), f], timeout=900).stdout
    found = re.findall(r'T=_text_runtime=([0-9a-f]+)\s+slide=\+([0-9a-f]+)', out)
    if not found:
        print('slide.py 没有候选, 原文尾部:\n' + out[-1200:])
        return
    for T, slide in found:
        s = int(slide, 16)
        cnt = {}
        for a in ips:
            n = name_of(a - s)
            if n:
                n = re.sub(r'\+0x[0-9a-f]+$', '', n).split('$')[0]
                cnt[n] = cnt.get(n, 0) + 1
        top = sorted(cnt.items(), key=lambda kv: -kv[1])[:8]
        gp = sum(1 for a in ips if GETPPID + s <= a < GETPPID + s + 0x44)
        en = sum(1 for a in ips if ENTRY + s <= a < ENTRY + s + 0x1400)
        sv = sum(1 for a in ips if SVC_COMMON + s <= a < SVC_COMMON + s + 0x140)
        print('== slide=%s  入口区 %d  getppid %d  el0_svc_common %d' % (slide, en, gp, sv))
        for n, c in top:
            print('     %4d  %s' % (c, n))


main()
