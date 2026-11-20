#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""harvest: 看 kernel/kernelsu.ko 到底是什么（尺寸/ELF头），然后无条件还原成 rc80 并复证。"""
import sys, time
sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import from_config

api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")
KO = "/root/k/ksu/kernel/kernelsu.ko"
KO_BK = "/home/lucy/kernelsu_rc80_backup.ko"
RC80 = "98bf405273e8652cdb7fffcc3fe42dc2"


def attempt(fn, tries=5, wait=8):
    for i in range(tries):
        try:
            return fn()
        except Exception as e:
            print("   [retry %d/%d] %s" % (i + 1, tries, str(e).splitlines()[-1][:90]))
            time.sleep(wait)
    raise SystemExit("!! 多次重试仍失败")


q = attempt(lambda: api.exec(
    "ls -l %s; md5sum %s; od -An -tx1 -N4 %s; "
    "ls -l /home/lucy/kernelsu_serial.ko 2>&1 | head -2; "
    "ls -l %s.log 2>&1 | head -2" % (KO, KO, KO, "/home/lucy/serial_build"), timeout=180))
print("=== 现读 ===")
print(q.stdout.strip())

rb = attempt(lambda: api.exec("cp -f %s %s && md5sum %s" % (KO_BK, KO, KO), timeout=180))
print("\n=== 还原 ===")
print(rb.stdout.strip())
chk = attempt(lambda: api.exec("md5sum %s %s" % (KO, KO_BK), timeout=120))
print(chk.stdout.strip())
got = chk.stdout.split()[0]
print("\n==> kernel/kernelsu.ko =", got, "OK(rc80)" if got == RC80 else "!!!MISMATCH")
