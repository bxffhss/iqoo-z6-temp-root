#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Verify the freshly built rc79 kernelsu.ko:
  - remote: size, undefined-symbol count, __versions/.text section sizes,
    presence of trampoline/dispatcher string markers, FA0/FS0 print count,
    that ksu_orig_syscall_table is referenced.
  - local : pull ko -> kmod/kernelsu_rc79.ko, compute md5.
"""
import sys, hashlib
sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import HermesRemote, from_config

api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")
KO = "/root/k/ksu/kernel/kernelsu.ko"

# --- remote checks -------------------------------------------------------
r = api.exec(f"ls -l {KO}", timeout=60)
print("==> ls -l:")
print(r.stdout.strip())

r = api.exec(f"llvm-nm -u {KO} 2>/dev/null | wc -l", timeout=60)
undef = int(r.stdout.strip())
print("==> undefined-symbol count (llvm-nm -u):", undef, "(rc78 baseline was 158)")

r = api.exec(f"llvm-nm {KO} 2>/dev/null | grep -i 'ksu_orig_syscall_table'", timeout=60)
print("==> ksu_orig_syscall_table symbol refs:")
print(r.stdout.strip() or "(none found)")

r = api.exec(f"llvm-objdump -h {KO} 2>/dev/null | grep -E '__versions|\\.text|\\.data'", timeout=60)
print("==> section sizes (__versions / .text / .data):")
print(r.stdout.strip())

r = api.exec(f"strings {KO} 2>/dev/null | grep -E 'KSUBEAT (BN|M2|M3|F9|B) '", timeout=60)
print("==> KSUBEAT markers present:")
print(r.stdout.strip() or "(none)")

r = api.exec(f"strings {KO} 2>/dev/null | grep -cE 'FA0|FS0|FS5'", timeout=60)
print("==> FA0/FS0/FS5 literal count (expect 0):", r.stdout.strip())

# --- pull ko locally for md5 --------------------------------------------
home = "kernelsu_rc79_pull"
r = api.exec(f"cp {KO} /home/lucy/{home}", timeout=60)
if r.exit_code != 0:
    print("CP FAIL", r.stderr.strip()[:200]); sys.exit(1)
data = api.read_bytes(home)
out = r"G:/项目/Windows管理/usb/临时root/kmod/kernelsu_rc79.ko"
with open(out, "wb") as f:
    f.write(data)
md5 = hashlib.md5(data).hexdigest()
print(f"==> wrote {out} ({len(data)} bytes)")
print(f"==> md5: {md5}")

# undefined symbols list (small) for record
r = api.exec(f"llvm-nm -u {KO} 2>/dev/null | head -40", timeout=60)
print("==> first undefined symbols:")
print(r.stdout.strip())
