#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""抢救 Exp-8 的构建产物（编译在远端真跑过了，只是拉回那一步被 504 打断）。
顺序：①看 build log ②确认是本次产物（符号闸）③拷成谱系名＋拉回 ④把 kernel/kernelsu.ko 还原成 rc80 ⑤复证
"""
import sys, time, hashlib
sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import from_config

api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")
LOG = "/home/lucy/serial_build.log"
KO = "/root/k/ksu/kernel/kernelsu.ko"
KO_BK = "/home/lucy/kernelsu_rc80_backup.ko"
KO_HOME = "/home/lucy/kernelsu_serial.ko"
LOCAL = r"G:/项目/Windows管理/usb/临时root/kmod/kernelsu_serial.ko"
RC80 = "98bf405273e8652cdb7fffcc3fe42dc2"


def attempt(fn, tries=5, wait=8):
    for i in range(tries):
        try:
            return fn()
        except Exception as e:
            print("   [retry %d/%d] %s" % (i + 1, tries, str(e).splitlines()[-1][:90]))
            time.sleep(wait)
    raise SystemExit("!! 多次重试仍失败")


print("=== ① build log 尾部 ===")
lg = attempt(lambda: api.read(LOG))
ll = lg.splitlines()
print("   日志行数:", len(ll))
for ln in ll[-12:]:
    print("   ", ln)
warn = [l for l in ll if "warning:" in l or "error:" in l]
print("   warning/error 计数:", len(warn))
for w in warn[:12]:
    print("   WARN/ERR:", w)
exitok = any("EXITCODE=0" in l for l in ll)
print("   EXITCODE=0 ?", exitok)
if not exitok:
    raise SystemExit("!! 编译没成功，按未完成处理（不抢救产物）")

print("\n=== ② 符号闸：这个 ko 是不是带串行闸的产物 ===")
sym = attempt(lambda: api.exec(
    "cd /root/k/ksu/kernel && md5sum kernelsu.ko && "
    "llvm-nm kernelsu.ko 2>/dev/null | grep -E 'ksu_exp6_serial|ksu_serial_busy|ksu_serial_entered|ksu_serial_skipped|ksu_exp6_mode' ; "
    "echo '--- 串闸计数 ---'; llvm-nm kernelsu.ko | grep -c 'ksu_serial'", timeout=180))
print(sym.stdout.strip())

print("\n=== ③ 拷成谱系名并拉回 ===")
cp = attempt(lambda: api.exec("cp -f %s %s && ls -l %s && md5sum %s" % (KO, KO_HOME, KO_HOME, KO_HOME),
                              timeout=180))
print(cp.stdout.strip())
data = attempt(lambda: api.read_bytes("kernelsu_serial.ko"))
print("==> 拉回字节数:", len(data), "md5:", hashlib.md5(data).hexdigest())
if len(data) > 100000:
    open(LOCAL, "wb").write(data)
    print("==> 已写本地:", LOCAL)
else:
    print("!! 尺寸异常，未写入")

print("\n=== ④ 把 kernel/kernelsu.ko 还原成 rc80 ===")
rb = attempt(lambda: api.exec("cp -f %s %s && md5sum %s" % (KO_BK, KO, KO), timeout=180))
print(rb.stdout.strip())
chk = attempt(lambda: api.exec("md5sum %s" % KO, timeout=120))
got = chk.stdout.split()[0]
print("==> kernel/kernelsu.ko 现读 =", got, "OK" if got == RC80 else "!!!MISMATCH")

print("\n=== ⑤ 两份源码复证 ===")
v = attempt(lambda: api.exec(
    "md5sum /root/k/ksu/kernel/hook/syscall_event_bridge.c /root/k/ksu/kernel/feature/sucompat.c",
    timeout=120))
print(v.stdout.strip())
