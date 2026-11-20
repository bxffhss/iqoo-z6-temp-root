#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Exp-6 构建（§6.599）：handler 体「三支单步隔离」。

背景（§6.598 已定案）：
  Exp-4（不进 dispatcher，活 772s）＋ Exp-5′（进 dispatcher、handler 空，活 996.8s）
  vs Exp-1（全 handler，18s 崩）⇒ 死因在 ksu_hook_execve handler 本体，不在钩子机制。

本格设计（只动 hook/syscall_event_bridge.c 一个文件，4 处）：
  新增模块参数 ksu_exp6_mode：
    0 = 全开（＝Exp-1 基线，用于同谱系自洽对照）
    1 = **只留 sucompat 一支**（摘 ksud / sulog）
    2 = 只留 ksud 一支（摘 sulog / sucompat）
    3 = 只留 sulog 一支（摘 ksud / sucompat）
    4 = 三支全摘（≈ Exp-5′ 的 noop，本谱系自洽对照）

源码走查结论（决定首发 mode=1）：
  - ksud 支：普通 execve 只两次 memcmp（`system_bin_init` / `app_process`），首个 zygote 后
    `ksu_stop_ksud_execve_hook()` 自禁 ⇒ 稳态很轻；
  - sulog 支：`ksu_sulog_capture()` 首行 `if (!ksu_sulog_is_enabled()) return NULL;` ⇒ 本机
    没人开 sulog 时是空返回；
  - sucompat 支：`sucompat.c:283-289` 对**每一个非名单 uid（含 root，因 forbid_system_uid
    对 uid<10000 直接 false）**无条件 `pr_info("KSUBEAT SD1 decline...")` ⇒ **execve 热路
    上每条一次 printk**，与 §6.585 记的 PS_HOLD 机制同形。

用法：python build_exp6.py            # 预览：打补丁 + 打印 diff，不碰远端
     python build_exp6.py --apply    # 备份+上传+编译+拉回+无条件还原
"""
import sys, os, hashlib, base64, difflib

sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import from_config

REMOTE = "/root/k/ksu/kernel/hook/syscall_event_bridge.c"
BACKUP = "/tmp/seb_exp6_orig.c"
MDIR = "/root/k/ksu/kernel"
KDIR = "/root/k/nothing_sm7325_v_mr"
LOG = "/home/lucy/exp6_build.log"
KO_REMOTE = "/root/k/ksu/kernel/kernelsu.ko"
KO_RC80_BK = "/home/lucy/kernelsu_rc80_backup.ko"
KO_HOME = "/home/lucy/kernelsu_exp6.ko"
LOCAL_BASE = r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/seb_remote_now.c"
LOCAL_KO = r"G:/项目/Windows管理/usb/临时root/kmod/kernelsu_exp6.ko"
RC80_KO = r"G:/项目/Windows管理/usb/临时root/kmod/kernelsu_rc80.ko"
# 远端 syscall_event_bridge.c 真实基线（probe_exp6_base.py 现读，LF 原件 4379 B）
BASELINE_MD5 = "26dd9a0af093d31d04ec73484a530fee"
APPLY = "--apply" in sys.argv

api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")


def md5b(b):
    return hashlib.md5(b).hexdigest()


raw = open(LOCAL_BASE, "rb").read().decode("utf-8")
base = raw.replace("\r\n", "\n")
if md5b(base.encode()) != BASELINE_MD5:
    raise SystemExit("!! 本地打补丁基线 md5=%s != 期望 %s，拒绝打补丁"
                     % (md5b(base.encode()), BASELINE_MD5))

ANCHOR_FN = ("static long __nocfi ksu_hook_execve_common(int orig_nr, "
             "const struct pt_regs *regs, bool execveat)\n{")

OLD_KSUD = "    if (static_branch_unlikely(&ksud_execve_key)) {"
OLD_SULOG = ("    if (current_euid().val == 0)\n"
             "        pending_root_execve = ksu_sulog_capture_root_execve("
             "*filename_user, argv_user, GFP_KERNEL);")
OLD_SUCOMPAT = "    } else if (ksu_su_compat_enabled) {"

NEW_KSUD = ("    if ((ksu_exp6_mode == 0 || ksu_exp6_mode == 2) && "
            "static_branch_unlikely(&ksud_execve_key)) {")
NEW_SULOG = ("    if ((ksu_exp6_mode == 0 || ksu_exp6_mode == 3) && current_euid().val == 0)\n"
             "        pending_root_execve = ksu_sulog_capture_root_execve("
             "*filename_user, argv_user, GFP_KERNEL);")
NEW_SUCOMPAT = ("    } else if ((ksu_exp6_mode == 0 || ksu_exp6_mode == 1) && "
                "ksu_su_compat_enabled) {")

EXP6_BLOCK = """/* ===== EXP6(§6.599)：handler 体三支单步隔离 =====
 * ksu_exp6_mode: 0=全开(＝Exp-1 基线) 1=只留 sucompat 2=只留 ksud 3=只留 sulog
 *                4=三支全摘(≈Exp-5' noop，本谱系自洽对照)
 * 目的：§6.598 已把死因锁进 handler 本体；本参数把三支拆开，一发只验一支。
 */
unsigned ksu_exp6_mode = 0;
module_param(ksu_exp6_mode, uint, 0);

"""

for a in (ANCHOR_FN, OLD_KSUD, OLD_SULOG, OLD_SUCOMPAT):
    if base.count(a) != 1:
        raise SystemExit("!! 锚点缺失或非唯一(count=%d)，拒绝打补丁：\n%s"
                         % (base.count(a), a[:120]))

patched = base.replace(ANCHOR_FN, EXP6_BLOCK + ANCHOR_FN, 1)
patched = patched.replace(OLD_KSUD, NEW_KSUD, 1)
patched = patched.replace(OLD_SULOG, NEW_SULOG, 1)
patched = patched.replace(OLD_SUCOMPAT, NEW_SUCOMPAT, 1)

if "#include <linux/module.h>" not in patched:
    inc_anchor = "#include \"klog.h\" // IWYU pragma: keep"
    if inc_anchor not in patched:
        raise SystemExit("!! include 锚点缺失")
    patched = patched.replace(inc_anchor, "#include <linux/module.h>\n" + inc_anchor, 1)

new_bytes = patched.encode("utf-8")
print("==> 基线 %d 字节 md5=%s" % (len(base.encode()), md5b(base.encode())))
print("==> 补丁件 %d 字节 md5=%s" % (len(new_bytes), md5b(new_bytes)))

print("\n=== diff（应只有：+include module.h / +EXP6 参数块 / 3 处守卫）===")
for line in difflib.unified_diff(base.splitlines(), patched.splitlines(),
                                 "baseline", "exp6", lineterm="", n=2):
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

    dv = api.exec("diff -u %s %s | head -60" % (BACKUP, REMOTE), timeout=120)
    print("==> 远端 diff（前 60 行）:\n" + dv.stdout)

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
    data = api.read_bytes("kernelsu_exp6.ko")
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

print("\n==> 结果:", "EXP6_KO_OK" if ok and restored else "FAILED_SEE_ABOVE")
