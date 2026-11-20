#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把远端两份源码无条件还原到基线，并复证 ko 仍是 rc80。
网络抖（WebSocket 504）时会重试；每一轮都重新 ping。
"""
import sys, time
sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import from_config

api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")

PAIRS = [
    ("/root/k/ksu/kernel/hook/syscall_event_bridge.c", "/tmp/seb_serial_orig.c",
     "26dd9a0af093d31d04ec73484a530fee", "seb"),
    ("/root/k/ksu/kernel/feature/sucompat.c", "/tmp/sucompat_serial_orig.c",
     "0a305171e7b5b1bb338862ee9639e974", "sucompat"),
]
KO = "/root/k/ksu/kernel/kernelsu.ko"
KO_MD5 = "98bf405273e8652cdb7fffcc3fe42dc2"


def attempt(fn, tries=4, wait=6):
    last = None
    for i in range(tries):
        try:
            return fn()
        except Exception as e:
            last = e
            print("   [retry %d/%d] %s" % (i + 1, tries, str(e).splitlines()[-1][:90]))
            time.sleep(wait)
    raise last


ok_all = True
for path, bk, want, name in PAIRS:
    try:
        r = attempt(lambda: api.exec("cp -f %s %s && md5sum %s" % (bk, path, path), timeout=120))
        got = r.stdout.split()[0] if r.stdout.split() else ""
    except Exception as e:
        print("!! %s 还原失败：%s" % (name, e))
        ok_all = False
        continue
    ok = got == want
    ok_all = ok_all and ok
    print("==> 还原 %-9s md5=%s %s" % (name, got, "OK" if ok else "!!!MISMATCH(期望 %s)" % want))

try:
    r = attempt(lambda: api.exec("md5sum %s /home/lucy/kernelsu_rc80_backup.ko" % KO, timeout=120))
    print("==> 现读 ko / 备份件:\n%s" % r.stdout.strip())
    if KO_MD5 not in r.stdout:
        print("!! kernelsu.ko 不是 rc80 ⇒ 需要用备份件覆盖")
        r2 = attempt(lambda: api.exec("cp -f /home/lucy/kernelsu_rc80_backup.ko %s && md5sum %s"
                                      % (KO, KO), timeout=120))
        print("==> 覆盖结果:", r2.stdout.strip())
except Exception as e:
    print("!! ko 复核失败：%s" % e)
    ok_all = False

print("\n==> RESTORE:", "ALL_OK" if ok_all else "SEE_ABOVE")
