#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Run the KernelSU external-module build on the remote machine and
capture the exit code + any compiler warnings.  KCFLAGS contains a space
so it must be quoted inside the remote shell (we pass one big quoted line).
"""
import sys
sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import HermesRemote, from_config

api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")

KDIR = "/root/k/nothing_sm7325_v_mr"
MDIR = "/root/k/ksu/kernel"
LOG  = "/home/lucy/rc79_build.log"

# Single shell line; KCFLAGS quoted so "-include /home/lucy/ksu_compat54.h"
# is passed as ONE argument.
make = (
    f"cd {KDIR} && "
    f"make -C {KDIR} M={MDIR} src={MDIR} CONFIG_KSU=m ARCH=arm64 "
    f"CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld AR=llvm-ar "
    f"NM=llvm-nm OBJCOPY=llvm-objcopy STRIP=llvm-strip "
    f'KCFLAGS="-include /home/lucy/ksu_compat54.h" '
    f"modules -j32 > {LOG} 2>&1; echo EXITCODE=$?"
)

print("==> running remote build (this may take a few minutes) ...")
r = api.exec(make, timeout=600)
print("exit_code:", r.exit_code)
print("stderr:", r.stderr.strip()[:300])

# Pull the log to inspect warnings / result.
data = api.read_bytes("rc79_build.log")
txt = data.decode("utf-8", "replace")
print("==> log length:", len(txt))
# Show the tail (the link step + any final errors)
lines = txt.splitlines()
print("==> last 40 lines:")
for ln in lines[-40:]:
    print(ln)

# Count warnings
warn = [l for l in lines if "warning:" in l or "error:" in l]
print("==> warning/error count:", len(warn))
for w in warn[:40]:
    print("   ", w)
