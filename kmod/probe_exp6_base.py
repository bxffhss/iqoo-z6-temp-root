#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Exp-6 前置：摸远端 syscall_event_bridge.c 的真实基线，并与本地副本对比。
零设备风险；只读。"""
import sys, hashlib, base64

sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import from_config

REMOTE = "/root/k/ksu/kernel/hook/syscall_event_bridge.c"
LOCAL_NOW = r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/seb_remote_now.c"
LOCAL_REF = r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/syscall_event_bridge.c"

api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")
print("==> ping:", api.ping())

r = api.exec("ls -l %s; md5sum %s" % (REMOTE, REMOTE), timeout=120)
print(r.stdout.strip())

md5 = None
for ln in r.stdout.splitlines():
    p = ln.split()
    if len(p) == 2 and len(p[0]) == 32:
        md5 = p[0]
print("==> remote md5 =", md5)

# 用 exec+base64 拿内容（/root 不在 read_bytes 的 $HOME 索引里）
b = api.exec("base64 -w0 %s" % REMOTE, timeout=180)
raw = base64.b64decode("".join(b.stdout.split()))
print("==> remote bytes =", len(raw), "recomputed md5 =", hashlib.md5(raw).hexdigest())
open(LOCAL_NOW, "wb").write(raw)
print("==> 落盘:", LOCAL_NOW)

try:
    ref = open(LOCAL_REF, "rb").read()
    print("==> 本地旧副本 bytes =", len(ref), "md5 =", hashlib.md5(ref).hexdigest())
    print("==> 与远端一致?", "YES" if ref == raw else "NO")
except Exception as e:
    print("!! 读本地旧副本失败:", e)
