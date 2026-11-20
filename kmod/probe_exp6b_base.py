#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Exp-6b 前置：摸远端 feature/sucompat.c 真基线（零设备风险，只读）。"""
import sys, hashlib, base64

sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import from_config

REMOTE = "/root/k/ksu/kernel/feature/sucompat.c"
LOCAL_NOW = r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/sucompat_remote_now.c"
LOCAL_REF = r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/sucompat.c"

api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")
print("==> ping:", bool(api.ping()))

r = api.exec("ls -l %s; md5sum %s" % (REMOTE, REMOTE), timeout=120)
print(r.stdout.strip())

b = api.exec("base64 -w0 %s" % REMOTE, timeout=180)
raw = base64.b64decode("".join(b.stdout.split()))
print("==> remote bytes =", len(raw), "md5 =", hashlib.md5(raw).hexdigest())
open(LOCAL_NOW, "wb").write(raw)

txt = raw.decode("utf-8", "replace").replace("\r\n", "\n")
print("\n=== 前 40 行 ===")
for i, ln in enumerate(txt.split("\n")[:40], 1):
    print("%3d| %s" % (i, ln))

print("\n=== 热路径打印标记计数 ===")
for pat in ('pr_info("KSUBEAT S', 'pr_warn("KSUBEAT S', 'pr_err("KSUBEAT S',
            'pr_info("KSUBEAT SD', 'pr_info("KSUBEAT SU'):
    print("  %-26s %d" % (pat, txt.count(pat)))

print("\n=== 重复的 path[0] = 0; 行数 ===")
print("  ", txt.count("    path[0] = 0;"))

print("\n=== 是否有 module.h / module_param ===")
print("  module.h:", "linux/module.h" in txt, "| module_param:", "module_param" in txt)

try:
    ref = open(LOCAL_REF, "rb").read()
    print("\n本地旧副本 bytes =", len(ref), "md5 =", hashlib.md5(ref).hexdigest(),
          "| 与远端一致?", "YES" if ref == raw else "NO")
except Exception as e:
    print("!! 读本地旧副本失败:", e)
