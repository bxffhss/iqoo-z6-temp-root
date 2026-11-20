#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rc81 探针：定位远端 sucompat.c，打印「允许判定 → 读文件名」那一段的原文行号，
   确认 rc81 的插入锚点存在（找不到就停，绝不盲改）。只读，不改任何文件。"""
import sys
sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import from_config

api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")
print("ping:", api.ping())

r = api.exec("find /root/k/ksu -name 'sucompat*.c' | head -20", timeout=120)
print("--- find ---")
print(r.stdout.strip() or r.stderr.strip())

CAND = "/root/k/ksu/kernel/supercall/sucompat.c"
for p in [CAND, "/root/k/ksu/kernel/sucompat.c", "/root/k/ksu/kernel/feature/sucompat.c"]:
    chk = api.exec(f"test -f {p} && md5sum {p} && wc -l {p}", timeout=60)
    print(f"--- {p} --- rc={chk.exit_code} {chk.stdout.strip()}")

# 打印锚点附近
g = api.exec(
    f"grep -n -e 'ksu_is_allow_uid_for_current' -e 'strncpy_from_user' -e 'memcmp(path, su_path' -e 'do_orig_execve' {CAND} | head -20",
    timeout=60)
print("--- 锚点行号 ---")
print(g.stdout.strip() or g.stderr.strip())
