# -*- coding: utf-8 -*-
"""solve_only.py — 只解本次开机的 KASLR slide, 不 punch、不重启(手跑 ishell 前的前置)。
复用 auto.py 的同一条路: perfips 自采样 -> analysis/slide_pc.py 正对照求解。"""
import io, os, re, subprocess, sys

ADB = r'C:\adb\platform-tools\adb.exe'
DEV = '<DEVICE_SERIAL>'
BASE = r'G:\项目\Windows管理\usb\临时root'
for _n in ('stdout', 'stderr'):
    try:
        getattr(sys, _n).reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass


def sh(args, **kw):
    kw.setdefault('capture_output', True)
    kw.setdefault('text', True)
    kw.setdefault('encoding', 'utf-8')
    kw.setdefault('errors', 'replace')
    return subprocess.run(args, **kw)


secs = int(sys.argv[1]) if len(sys.argv) > 1 else 25
sh([ADB, '-s', DEV, 'shell', 'rm -f /data/local/tmp/ipk.txt'])
sh([ADB, '-s', DEV, 'shell', '/data/local/tmp/perfips %d > /data/local/tmp/ipk.txt' % secs],
   timeout=secs + 180)
out = sh([ADB, '-s', DEV, 'shell', 'cat /data/local/tmp/ipk.txt'], timeout=120).stdout
ips = set()
for l in (out or '').splitlines():
    m = re.search(r'([0-9a-f]{12,16})\s*$', l.strip())
    if m:
        v = int(m.group(1), 16)
        if v >= 0xffff000000000000:
            ips.add(v)
print('内核态样本 =', len(ips), flush=True)
if len(ips) < 50:
    raise SystemExit('正对照采样太少, 停(不猜)')
f = r'C:\qemu_test\ips_solve_only.txt'
io.open(f, 'w', encoding='utf-8').write('\n'.join('%x' % a for a in sorted(ips)) + '\n')
r = sh([sys.executable, os.path.join(BASE, 'analysis', 'slide_pc.py'), f], timeout=900)
print(((r.stdout or '') + (r.stderr or '')).strip()[-1000:], flush=True)
m = re.search(r'^SLIDE ([0-9a-f]+)\s*$', r.stdout or '', re.M)
print('SOLVE_ONLY_RESULT ' + (m.group(1) if m else 'NONE'))
