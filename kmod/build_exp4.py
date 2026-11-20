#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Exp-4 构建（§6.595）：极简透传桩，隔离「模块代码常驻高频 syscall 路径」是否本身致命。

设计（只动 hook/arm64/syscall_hook.c 一个文件）：
  - 新增模块参数 ksu_exp4_passthru（0/1），默认 0 = 原 rc80 行为；
  - 新增 ksu_passthru_stub()：__nocfi、**完全不读 pt_regs**、不查 syscall_hooks、
    不调 handler，直接尾调 ksu_orig_syscall_table[ksu_exp4_nr]（槽位号在安装时记录）；
  - ksu_install_syscall_hook() 在 passthru=1 时装这个桩而不是 ksu_syscall_trampoline。

判读（一发定生死）：
  - 崩  ⇒ 「模块代码常驻高频 syscall 路径」本身致命 ⇒ 只剩 H-A(LSM) 一条路；
  - 活  ⇒ 死因在 dispatcher/handler/pt_regs 改写/orig 调用链，可定点修。

安全纪律：
  - 远端基线 md5 必须 == BASELINE_MD5，否则直接退出（不猜状态）；
  - 原件备份 /tmp/sh_exp4_orig.c，编译结束（无论成败）**无条件还原并复验 md5**；
  - 远端 kernelsu.ko 是 rc80 产物，先备份 /home/lucy/kernelsu_rc80_backup.ko 并核对；
  - 产出拉回本地 kmod/kernelsu_exp4.ko，绝不覆盖 kmod/kernelsu_rc80.ko。

用法：python build_exp4.py            # 预览：只打补丁+打印 diff，不碰远端
     python build_exp4.py --apply    # 真备份+上传+编译+拉回+还原
"""
import sys, os, hashlib, base64, difflib

sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import from_config

REMOTE = "/root/k/ksu/kernel/hook/arm64/syscall_hook.c"
BACKUP = "/tmp/sh_exp4_orig.c"
MDIR = "/root/k/ksu/kernel"
KDIR = "/root/k/nothing_sm7325_v_mr"
LOG = "/home/lucy/exp4_build.log"
KO_REMOTE = "/root/k/ksu/kernel/kernelsu.ko"
KO_RC80_BK = "/home/lucy/kernelsu_rc80_backup.ko"
KO_HOME = "/home/lucy/kernelsu_exp4.ko"
LOCAL_BASE = r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/syscall_hook_remote_now.c"
LOCAL_KO = r"G:/项目/Windows管理/usb/临时root/kmod/kernelsu_exp4.ko"
RC80_KO = r"G:/项目/Windows管理/usb/临时root/kmod/kernelsu_rc80.ko"
BASELINE_MD5 = "c5698c8dd4a132f70cc51cb4c48d856f"
APPLY = "--apply" in sys.argv

api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")


def md5b(b):
    return hashlib.md5(b).hexdigest()


# ---------- 1) 本地造补丁件 ----------
raw = open(LOCAL_BASE, "rb").read().decode("utf-8")
base = raw.replace("\r\n", "\n")

ANCHOR_INSTALL = "// Register @fn for @nr AND patch the syscall table slot to the shared"
OLD_INSTALL = """int ksu_install_syscall_hook(int nr, ksu_syscall_hook_fn fn)
{
    int rc = ksu_register_syscall_hook(nr, fn);
    if (rc)
        return rc;
    if (ksu_syscall_table)
        ksu_syscall_table_hook(nr, (syscall_fn_t)ksu_syscall_trampoline, NULL);
    return 0;
}"""

EXP4_BLOCK = """/* ===== EXP4 (§6.595)：极简透传桩 =====
 * 目的：把 sys_call_table 的槽位换成"只做尾调 orig、完全不读 pt_regs、不查
 * syscall_hooks、不调 handler"的模块函数，用以判别「模块代码常驻高频 syscall
 * 路径」本身是否致命（对照：0x0 不碰表＝稳；0x2/0x18/0x1a 走 dispatcher＝崩）。
 * 槽位号由安装时记录（ksu_exp4_nr），因此本桩对 kernel_execve 那种"假 regs"
 * 的调用形状也安全。ksu_exp4_passthru=1 时才生效。
 */
unsigned ksu_exp4_passthru = 0;
module_param(ksu_exp4_passthru, uint, 0);
static int ksu_exp4_nr = -1;

static long __nocfi ksu_passthru_stub(const struct pt_regs *regs)
{
    int nr = ksu_exp4_nr;
    if (likely(nr >= 0 && nr < __NR_syscalls) && ksu_orig_syscall_table[nr])
        return ksu_orig_syscall_table[nr](regs);
    return -ENOSYS;
}

"""

NEW_INSTALL = """int ksu_install_syscall_hook(int nr, ksu_syscall_hook_fn fn)
{
    int rc = ksu_register_syscall_hook(nr, fn);
    if (rc)
        return rc;
    if (ksu_syscall_table) {
        if (ksu_exp4_passthru) {
            ksu_exp4_nr = nr;
            pr_info("KSUBEAT EXP4 passthru stub armed for nr=%d (no regs read)\\n", nr);
            ksu_syscall_table_hook(nr, (syscall_fn_t)ksu_passthru_stub, NULL);
        } else {
            ksu_syscall_table_hook(nr, (syscall_fn_t)ksu_syscall_trampoline, NULL);
        }
    }
    return 0;
}"""

for a in (ANCHOR_INSTALL, OLD_INSTALL):
    if a not in base:
        raise SystemExit("!! 锚点缺失，拒绝打补丁：\n" + a[:80])

patched = base.replace(ANCHOR_INSTALL, EXP4_BLOCK + ANCHOR_INSTALL, 1)
patched = patched.replace(OLD_INSTALL, NEW_INSTALL, 1)

# 补 module.h（module_param 需要）
if "#include <linux/module.h>" not in patched:
    inc_anchor = "#include <linux/kallsyms.h>"
    patched = patched.replace(inc_anchor, inc_anchor + "\n#include <linux/module.h>", 1)

new_bytes = patched.encode("utf-8")
print("==> 基线 %d 字节 md5=%s" % (len(base.encode()), md5b(base.encode())))
print("==> 补丁件 %d 字节 md5=%s" % (len(new_bytes), md5b(new_bytes)))

print("\n=== diff（应只有：+include module.h / +EXP4 块 / ~install 函数）===")
for line in difflib.unified_diff(base.splitlines(), patched.splitlines(),
                                 "baseline", "exp4", lineterm="", n=2):
    print(line)

# 补丁面自检：改动行必须落在预期内
changed = [l for l in difflib.unified_diff(base.splitlines(), patched.splitlines(),
                                           lineterm="", n=0)
           if l.startswith(("+", "-")) and not l.startswith(("+++", "---"))]
print("\n==> 改动行数 =", len(changed))

if not APPLY:
    print("\n==> 预览模式：未碰远端。确认 diff 后可加 --apply。")
    sys.exit(0)

# ---------- 2) 远端基线校验 + 备份 ----------
print("\n==> ping:", api.ping())
cur = api.exec("md5sum %s" % REMOTE, timeout=120)
got = cur.stdout.split()[0] if cur.stdout.split() else ""
print("==> 远端现状 md5 =", got)
if got != BASELINE_MD5:
    raise SystemExit("!! 远端基线 md5 不符（期望 %s），拒绝改动。先人工核对。" % BASELINE_MD5)

bk = api.exec("cp -f %s %s && md5sum %s" % (REMOTE, BACKUP, BACKUP), timeout=120)
bk_md5 = bk.stdout.split()[0] if bk.stdout.split() else ""
print("==> 备份 %s md5=%s" % (BACKUP, bk_md5))
if bk_md5 != BASELINE_MD5:
    raise SystemExit("!! 备份 md5 不符，中止。")

# rc80 产物备份（编译会覆盖 kernelsu.ko）
rc = api.exec("cp -f %s %s && md5sum %s %s" % (KO_REMOTE, KO_RC80_BK, KO_REMOTE, KO_RC80_BK),
              timeout=180)
print("==> rc80 ko 备份:", rc.stdout.strip())
try:
    local_rc80 = md5b(open(RC80_KO, "rb").read())
    print("==> 本地 rc80 ko md5 =", local_rc80)
except Exception as e:
    print("!! 读本地 rc80 ko 失败:", e)


def restore():
    r = api.exec("cp -f %s %s && md5sum %s" % (BACKUP, REMOTE, REMOTE), timeout=120)
    g = r.stdout.split()[0] if r.stdout.split() else ""
    print("==> 还原 %s md5=%s %s" % (REMOTE, g, "OK" if g == BASELINE_MD5 else "!!!MISMATCH"))
    return g == BASELINE_MD5


ok = False
try:
    # ---------- 3) 上传补丁件 ----------
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

    # 远端 diff 复核
    dv = api.exec("diff -u %s %s | head -60" % (BACKUP, REMOTE), timeout=120)
    print("==> 远端 diff（前 60 行）:\n" + dv.stdout)

    # ---------- 4) 编译 ----------
    make = ("cd %s && make -C %s M=%s src=%s CONFIG_KSU=m ARCH=arm64 "
            "CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld AR=llvm-ar "
            "NM=llvm-nm OBJCOPY=llvm-objcopy STRIP=llvm-strip "
            'KCFLAGS="-include /home/lucy/ksu_compat54.h" '
            "modules -j32 > %s 2>&1; echo EXITCODE=$?") % (KDIR, KDIR, MDIR, MDIR, LOG)
    print("==> 编译中（可能几分钟）...")
    br = api.exec(make, timeout=900)
    print("==> build rc:", br.exit_code, "tail:", br.stdout.strip()[-80:])

    log = api.read(LOG)
    ll = log.splitlines()
    print("==> 日志行数:", len(ll))
    for ln in ll[-25:]:
        print("   ", ln)
    warn = [l for l in ll if "warning:" in l or " error:" in l]
    print("==> warning/error 计数:", len(warn))
    for w in warn[:20]:
        print("   W/E:", w)
    if "EXITCODE=0" not in br.stdout:
        raise SystemExit("!! 编译未成功（EXITCODE != 0），不拉产物")

    # ---------- 5) 拉回产物 ----------
    cp = api.exec("cp -f %s %s && ls -l %s && md5sum %s" % (KO_REMOTE, KO_HOME, KO_HOME, KO_HOME),
                  timeout=180)
    print("==> ko cp:", cp.stdout.strip())
    data = api.read_bytes("kernelsu_exp4.ko")
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
    # 同时把远端 kernelsu.ko 还原成 rc80（避免远端产物被实验件污染）
    rb = api.exec("cp -f %s %s && md5sum %s" % (KO_RC80_BK, KO_REMOTE, KO_REMOTE), timeout=180)
    print("==> 远端 kernelsu.ko 还原:", rb.stdout.strip())

print("\n==> 结果:", "EXP4_KO_OK" if ok and restored else "FAILED_SEE_ABOVE")
