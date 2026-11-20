#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Pull the 5 hook-layer source files from the remote build tree into kmod/rc79_src
for local editing.  Steps per file:
  1. exec `cp <remote_abs> /home/lucy/<home_name>`  (exec sees /root/k and $HOME)
  2. read_bytes(<home_name>)                          (bypasses the FileBrowser index)
  3. write the bytes to the local path.
Then push back via put + exec cp (see push_rc79_src.py).
"""
import sys, os
sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import HermesRemote, from_config

api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")

BASE = "/root/k/ksu/kernel"
ROOT = r"G:/项目/Windows管理/usb/临时root/kmod/rc79_src"

FILES = [
    ("hook/syscall_hook.h",            "sc_syscall_hook.h",            "hook/syscall_hook.h"),
    ("hook/arm64/syscall_hook.c",      "sc_arm64_syscall_hook.c",      "hook/arm64/syscall_hook.c"),
    ("hook/syscall_hook_manager.c",    "sc_syscall_hook_manager.c",    "hook/syscall_hook_manager.c"),
    ("hook/syscall_event_bridge.c",    "sc_syscall_event_bridge.c",    "hook/syscall_event_bridge.c"),
    ("feature/sucompat.c",             "sc_sucompat.c",               "feature/sucompat.c"),
]

for rel, home, local in FILES:
    remote_abs = BASE + "/" + rel
    # 1) copy into $HOME so read_bytes can reach it
    r = api.exec(f"cp {remote_abs} /home/lucy/{home} && wc -c /home/lucy/{home}", timeout=60)
    if r.exit_code != 0:
        print(f"CP FAIL {rel}: rc={r.exit_code} err={r.stderr.strip()[:120]}")
        sys.exit(1)
    # 2) read bytes
    try:
        data = api.read_bytes(home)
    except Exception as e:
        print(f"READ FAIL {rel}: {e}")
        sys.exit(1)
    if not data:
        print(f"EMPTY {rel}")
        sys.exit(1)
    # 3) write local
    out = os.path.join(ROOT, local)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as f:
        f.write(data)
    print(f"OK {rel} -> {out} ({len(data)} bytes)")
print("DONE")
