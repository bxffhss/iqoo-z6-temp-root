#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""绕过 cli.py get 的 exists 守卫，直接用 hrmt.read_bytes 把远端 ko 拉回本地。
候选路径都试一遍，命中第一个能读到非空内容的。"""
import sys
sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import HermesRemote, from_config

OUT = r"G:/项目/Windows管理/usb/临时root/kmod/ksud_rc77.ko"
CANDIDATES = [
    "/home/lucy/ksud_rc77.ko",
    "/home/lucy/mount/ksud_rc77.ko",
    "ksud_rc77.ko",
    "/home/lucy/mount/ksud_rc77.ko",
]

api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")
for p in CANDIDATES:
    try:
        data = api.read_bytes(p)
    except Exception as e:
        print("ERR %s -> %s" % (p, e))
        continue
    print("path=%s status bytes=%d" % (p, len(data)))
    if len(data) > 100000:  # 有效 ko 至少几百 KB
        with open(OUT, "wb") as f:
            f.write(data)
        print("WROTE %s (%d bytes)" % (OUT, len(data)))
        sys.exit(0)
print("FAILED: no candidate returned a valid ko")
sys.exit(1)
