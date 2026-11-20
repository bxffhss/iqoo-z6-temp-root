#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Exp-5′ 构建（§6.597）：空透传 handler —— 把「dispatcher 层」与「handler 本体」分开。

设计（只动 hook/syscall_hook_manager.c 一个文件）：
  - 新增模块参数 ksu_exp5_noop（0/1），默认 0 = 原 rc80 行为；
  - 新增 ksu_hook_noop(orig_nr, regs)：立刻 return ksu_orig_syscall_table[orig_nr](regs)；
  - bit1(execve) 注册时，ksu_exp5_noop=1 ⇒ 注册 ksu_hook_noop 而不是 ksu_hook_execve。
  ⇒ trampoline→dispatcher 照旧全程跑（含 regs 哨兵/还原、syscall_hooks 查表），
    唯一差别＝handler 本体换成一句尾调。

判读：
  - 崩  ⇒ dispatcher 层（trampoline 的 regs 改写 + dispatcher 那次额外栈帧/查表）致命；
  - 活  ⇒ handler 本体致命（首嫌 sucompat 的 is_ksud_exists()→kern_path 可睡眠 / allowlist RCU）。

参考：Exp-4 已证「模块代码常驻热路径 + 调 orig」不致命（存活 772s，§6.596/§6.597）。

用法：python build_exp5.py            # 预览：只打补丁+打印 diff，不碰远端
     python build_exp5.py --apply    # 备份+上传+编译+拉回+无条件还原
"""
import sys, os, hashlib, base64, difflib

sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import from_config

REMOTE = "/root/k/ksu/kernel/hook/syscall_hook_manager.c"
BACKUP = "/tmp/sh_mgr_exp5_orig.c"
MDIR = "/root/k/ksu/kernel"
KDIR = "/root/k/nothing_sm7325_v_mr"
LOG = "/home/lucy/exp5_build.log"
KO_REMOTE = "/root/k/ksu/kernel/kernelsu.ko"
KO_RC80_BK = "/home/lucy/kernelsu_rc80_backup.ko"
KO_HOME = "/home/lucy/kernelsu_exp5.ko"
LOCAL_BASE = r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/sh_mgr_remote_now.c"
LOCAL_KO = r"G:/项目/Windows管理/usb/临时root/kmod/kernelsu_exp5.ko"
RC80_KO = r"G:/项目/Windows管理/usb/临时root/kmod/kernelsu_rc80.ko"
BASELINE_MD5 = "7e615780b8c83310bdd98e803d6bfad3"
APPLY = "--apply" in sys.argv

api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")


def md5b(b):
    return hashlib.md5(b).hexdigest()


raw = open(LOCAL_BASE, "rb").read().decode("utf-8")
base = raw.replace("\r\n", "\n")

ANCHOR_INIT = "void __init ksu_syscall_hook_manager_init(void)"
OLD_LINE = ("    if (ksu_hook_mask & (1U << 1)) { ksu_install_syscall_hook(__NR_execve, ksu_hook_execve); }")
NEW_LINE = ("    if (ksu_hook_mask & (1U << 1)) { ksu_install_syscall_hook(__NR_execve, "
            "ksu_exp5_noop ? ksu_hook_noop : ksu_hook_execve); }")

EXP5_BLOCK = """/* ===== EXP5'(§6.597)：空透传 handler =====
 * 目的：把「dispatcher 层」与「handler 本体」分开判定。trampoline→dispatcher 照旧全程跑
 * （含 regs 哨兵/还原、syscall_hooks 查表、那次额外栈帧），只把 handler 换成本透传。
 * 参考 Exp-4：模块代码常驻热路径 + 调 orig 本身不致命（存活 772s）。
 * ksu_exp5_noop=1 时 execve 注册成这个。
 */
unsigned ksu_exp5_noop = 0;
module_param(ksu_exp5_noop, uint, 0);

static long ksu_hook_noop(int orig_nr, const struct pt_regs *regs)
{
    return ksu_orig_syscall_table[orig_nr](regs);
}

"""

for a in (ANCHOR_INIT, OLD_LINE):
    if a not in base:
        raise SystemExit("!! 锚点缺失，拒绝打补丁：\n" + a[:100])

patched = base.replace(ANCHOR_INIT, EXP5_BLOCK + ANCHOR_INIT, 1)
patched = patched.replace(OLD_LINE, NEW_LINE, 1)

if "#include <linux/module.h>" not in patched:
    inc_anchor = "#include \"klog.h\" // IWYU pragma: keep"
    if inc_anchor not in patched:
        raise SystemExit("!! include 锚点缺失")
    patched = patched.replace(inc_anchor,
                              "#include <linux/module.h>\n" + inc_anchor, 1)

new_bytes = patched.encode("utf-8")
print("==> 基线 %d 字节 md5=%s" % (len(base.encode()), md5b(base.encode())))
print("==> 补丁件 %d 字节 md5=%s" % (len(new_bytes), md5b(new_bytes)))

print("\n=== diff（应只有：+include module.h / +EXP5 块 / ~bit1 注册行）===")
for line in difflib.unified_diff(base.splitlines(), patched.splitlines(),
                                 "baseline", "exp5", lineterm="", n=2):
    print(line)

changed = [l for l in difflib.unified_diff(base.splitlines(), patched.splitlines(),
                                           lineterm="", n=0)
           if l.startswith(("+", "-")) and not l.startswith(("+++", "---"))]
print("\n==> 改动行数 =", len(changed))

if not APPLY:
    print("\n==> 预览模式：未碰远端。确认 diff 后可加 --apply。")
    sys.exit(0)

print("\n==> ping:", api.ping())
cur = api.exec("md5sum %s" % REMOTE, timeout=120)
got = cur.stdout.split()[0] if cur.stdout.split() else ""
print("==> 远端现状 md5 =", got)
if got != BASELINE_MD5:
    raise SystemExit("!! 远端基线 md5 不符（期望 %s），拒绝改动。" % BASELINE_MD5)

bk = api.exec("cp -f %s %s && md5sum %s" % (REMOTE, BACKUP, BACKUP), timeout=120)
bk_md5 = bk.stdout.split()[0] if bk.stdout.split() else ""
print("==> 备份 %s md5=%s" % (BACKUP, bk_md5))
if bk_md5 != BASELINE_MD5:
    raise SystemExit("!! 备份 md5 不符，中止。")

rc = api.exec("cp -f %s %s && md5sum %s" % (KO_REMOTE, KO_RC80_BK, KO_RC80_BK), timeout=180)
print("==> rc80 ko 备份:", rc.stdout.strip())
try:
    print("==> 本地 rc80 ko md5 =", md5b(open(RC80_KO, "rb").read()))
except Exception as e:
    print("!! 读本地 rc80 ko 失败:", e)


def restore():
    r = api.exec("cp -f %s %s && md5sum %s" % (BACKUP, REMOTE, REMOTE), timeout=120)
    g = r.stdout.split()[0] if r.stdout.split() else ""
    print("==> 还原 %s md5=%s %s" % (REMOTE, g, "OK" if g == BASELINE_MD5 else "!!!MISMATCH"))
    return g == BASELINE_MD5


ok = False
try:
    b64 = base64.b64encode(new_bytes).decode()
    chunks = [b64[i:i + 900] for i in range(0, len(b64), 900)]
    cmds = [": > %s.b64" % REMOTE]
    for c in chunks:
        cmds.append("printf %%s %s >> %s.b64" % (c, REMOTE))
    cmds += ["base64 -d %s.b64 > %s" % (REMOTE, REMOTE),
             "rm -f %s.b64" % REMOTE,
             "md5sum %s" % REMOTE]
    up = api.exec("\n".join(cmds), timeout=300)
    up_md5 = up.stdout.split()[0] if up.stdout.split() else ""
    print("==> 上传后远端 md5 =", up_md5)
    if up_md5 != md5b(new_bytes):
        raise SystemExit("!! 上传 md5 不符，中止（将还原）")

    dv = api.exec("diff -u %s %s | head -50" % (BACKUP, REMOTE), timeout=120)
    print("==> 远端 diff（前 50 行）:\n" + dv.stdout)

    make = ("cd %s && make -C %s M=%s src=%s CONFIG_KSU=m ARCH=arm64 "
            "CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld AR=llvm-ar "
            "NM=llvm-nm OBJCOPY=llvm-objcopy STRIP=llvm-strip "
            'KCFLAGS="-include /home/lucy/ksu_compat54.h" '
            "modules -j32 > %s 2>&1; echo EXITCODE=$?") % (KDIR, KDIR, MDIR, MDIR, LOG)
    print("==> 编译中（可能几分钟）...")
    br = api.exec(make, timeout=900)
    print("==> build rc:", br.exit_code, "tail:", br.stdout.strip()[-80:])
    if "EXITCODE=0" not in br.stdout:
        lg = api.read(LOG)
        for ln in lg.splitlines()[-15:]:
            print("   ", ln)
        raise SystemExit("!! 编译未成功")

    cp = api.exec("cp -f %s %s && ls -l %s && md5sum %s" % (KO_REMOTE, KO_HOME, KO_HOME, KO_HOME),
                  timeout=180)
    print("==> ko cp:", cp.stdout.strip())
    data = api.read_bytes("kernelsu_exp5.ko")
    print("==> 拉回字节数:", len(data), "md5:", md5b(data))
    if len(data) > 100000:
        open(LOCAL_KO, "wb").write(data)
        print("==> 已写本地:", LOCAL_KO)
        ok = True
    else:
        print("!! ko 尺寸异常，未写入")
finally:
    print("\n==> 还原远端源码 ...")
    restored = restore()
    rb = api.exec("cp -f %s %s && md5sum %s" % (KO_RC80_BK, KO_REMOTE, KO_REMOTE), timeout=180)
    print("==> 远端 kernelsu.ko 还原:", rb.stdout.strip())

print("\n==> 结果:", "EXP5_KO_OK" if ok and restored else "FAILED_SEE_ABOVE")
