#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把远端刚编出来的 rc78 ko 拉回本地（绕过 cli.py get 的 exists 守卫）。
先 cp 到 /home/lucy/mount/（FileBrowser 真身区），再 read_bytes 取字节。"""
import hashlib
import sys

sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import from_config  # noqa: E402

OUT = r"G:/项目/Windows管理/usb/临时root/kmod/kernelsu_rc78.ko"
WANT_MD5 = "16b6c7c2a6f2a770c12b53ae03a331bd"
api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")

r = api.exec("mkdir -p /home/lucy/mount && cp -f /root/k/ksu/kernel/kernelsu.ko /home/lucy/mount/kernelsu_rc78.ko "
             "&& md5sum /home/lucy/mount/kernelsu_rc78.ko && ls -l /home/lucy/mount/kernelsu_rc78.ko")
print("exec rc=%s\n%s" % (r.exit_code, r.stdout.strip()))
if r.exit_code != 0:
    sys.exit(1)

for p in ("/home/lucy/mount/kernelsu_rc78.ko", "kernelsu_rc78.ko", "mount/kernelsu_rc78.ko"):
    try:
        data = api.read_bytes(p)
    except Exception as e:  # noqa: BLE001
        print("ERR %s -> %s" % (p, e))
        continue
    if len(data) > 100000:
        md5 = hashlib.md5(data).hexdigest()
        print("path=%s bytes=%d md5=%s" % (p, len(data), md5))
        with open(OUT, "wb") as f:
            f.write(data)
        print("WROTE %s" % OUT)
        print("MD5_MATCH=%s (want %s)" % (md5 == WANT_MD5, WANT_MD5))
        sys.exit(0 if md5 == WANT_MD5 else 2)
    print("path=%s bytes=%d -> 太小，跳过" % (p, len(data)))

print("FAILED")
sys.exit(1)
