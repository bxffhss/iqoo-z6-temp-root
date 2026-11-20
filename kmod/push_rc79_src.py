#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Push the 5 edited hook-layer files back into the remote kernel tree:
  1. api.write(<home_name>, data)   -> lands in $HOME (FileBrowser)
  2. exec cp /home/lucy/<home_name> <remote_abs>   (exec sees the mount symlink)
"""
import sys, os, time
sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import HermesRemote, from_config

api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")
ROOT = r"G:/项目/Windows管理/usb/临时root/kmod/rc79_src"
TS = str(int(time.time()))[-5:]

FILES = [
    ("hook/syscall_hook.h",            "pt_sc_h_%s"  % TS, "/root/k/ksu/kernel/hook/syscall_hook.h"),
    ("hook/arm64/syscall_hook.c",      "pt_a64_%s"   % TS, "/root/k/ksu/kernel/hook/arm64/syscall_hook.c"),
    ("hook/syscall_hook_manager.c",    "pt_mgr_%s"   % TS, "/root/k/ksu/kernel/hook/syscall_hook_manager.c"),
    ("hook/syscall_event_bridge.c",    "pt_brg_%s"   % TS, "/root/k/ksu/kernel/hook/syscall_event_bridge.c"),
    ("feature/sucompat.c",             "pt_suc_%s"   % TS, "/root/k/ksu/kernel/feature/sucompat.c"),
]

for local, home, remote_abs in FILES:
    src = os.path.join(ROOT, local)
    data = open(src, "rb").read()
    via = api.write(home, data)
    r = api.exec(f"cp /home/lucy/{home} {remote_abs} && wc -c {remote_abs}", timeout=60)
    if r.exit_code != 0:
        print(f"CP FAIL {local}: rc={r.exit_code} {r.stderr.strip()[:200]}")
        sys.exit(1)
    c = r.stdout.strip().split()[0]
    if int(c) != len(data):
        print(f"SIZE MISMATCH {local}: wrote {len(data)} but file is {c}")
        sys.exit(1)
    print(f"PUSHED {local} -> {remote_abs} ({len(data)} bytes, via={via})")
print("DONE")
