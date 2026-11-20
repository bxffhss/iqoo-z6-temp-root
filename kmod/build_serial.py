#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Exp-8 构建（§6.609）：**把并发拍平** —— handler body 同一时刻只允许一个线程。

为什么要这一发（不是"再调个参数"）：
  §6.604 的读数**非比例**：decline 次数 727/s → 199/s（÷3.65），死亡时间只从 19.50 s
  挪到 20.75 s（+7.7%）。若死因是"每跑一次伤一次"，时间该拉长 ≈3.65 倍 ⇒ 不是累积损伤。
  §6.605 另一头：0.2 次/s 活过 1384 s。
  ⇒ 最自洽的模型是「**≥ ~200 次/秒 时某个锁/状态的交错概率饱和**」。
  而八发里从没有哪一发回答过"**同一时刻只进一个**"这个自变量：
    Exp-6d(cut=1) = 全不进；Exp-6f/6g(rate) = 少进；本发 = **同一时刻只进一个**。

形状（最小改动，单变量对照 Exp-6 的 19.50 s）：
  A) hook/syscall_event_bridge.c（基线 26dd9a0a…）：与 Exp-6 同款 3 处 mode 守卫
     （`ksu_exp6_mode=1` ⇒ 只留 sucompat 一支，摘掉 ksud/sulog）⇒ 与 Exp-6 逐字同形状。
  B) feature/sucompat.c（基线 0a305171…）：
     ① **清理 63 行重复的 `path[0] = 0;`**（建树时的非幂等补丁残留；上游 HEAD 是 0 遍，
        本树 +191/−39 行。功能上是 dead store，但留着会让真 diff 被噪声掩盖）
     ② 把 `..._common` 改名为 `..._inner`，原名字处放一个**串行闸包装**：
          抢到全局位 ⇒ 进 inner，出口无条件释放；
          抢不到     ⇒ 直接 `return ksu_orig_syscall_table[orig_nr](regs)`
                        （＝ cut=1 那条已证 ≥193.5 s 无害的路）
     ③ 正面见证：`KSUBEAT SER enter=/skip=` 只打 4 次（1/100/1000/10000）。
        ★`skip>0` 本身就是"并发真的发生过、闸真的拦到了"的证据，不用拿"没崩"倒推。
  ★**不做** quiet / cut / rate / noslow / nouid0 任何一项 ⇒ 与 Exp-6 相比只有"串行闸"一个变量。

★默认 0 ⇒ 行为与基线逐字同（外层 `likely(!ksu_exp6_serial)` 短路，连原子操作都不做）。
★真跑业务的窗口别开：并发 su 会被偶发丢掉（重试即可）；`0x2` 单钩下 su 命中路径本身是稀少的。

用法：python build_serial.py            # 预览（0 接触）
      python build_serial.py --apply    # 备份+上传+编译+拉回+无条件还原
"""
import sys, hashlib, base64, difflib

sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import from_config

SEB = "/root/k/ksu/kernel/hook/syscall_event_bridge.c"
SC = "/root/k/ksu/kernel/feature/sucompat.c"
BK_SEB = "/tmp/seb_serial_orig.c"
BK_SC = "/tmp/sucompat_serial_orig.c"
MDIR = "/root/k/ksu/kernel"
KDIR = "/root/k/nothing_sm7325_v_mr"
LOG = "/home/lucy/serial_build.log"
KO_REMOTE = "/root/k/ksu/kernel/kernelsu.ko"
KO_RC80_BK = "/home/lucy/kernelsu_rc80_backup.ko"
KO_HOME = "/home/lucy/kernelsu_serial.ko"
LOCAL_SEB = r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/seb_remote_now.c"
LOCAL_SC = r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/sucompat_remote_now.c"
LOCAL_KO = r"G:/项目/Windows管理/usb/临时root/kmod/kernelsu_serial.ko"
SEB_MD5 = "26dd9a0af093d31d04ec73484a530fee"
SC_MD5 = "0a305171e7b5b1bb338862ee9639e974"
RC80_MD5 = "98bf405273e8652cdb7fffcc3fe42dc2"
APPLY = "--apply" in sys.argv

api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")


def md5b(b):
    return hashlib.md5(b).hexdigest()


def load(p, expect):
    t = open(p, "rb").read().decode("utf-8").replace("\r\n", "\n")
    if md5b(t.encode()) != expect:
        raise SystemExit("!! %s 基线 md5=%s != 期望 %s" % (p, md5b(t.encode()), expect))
    return t


def diff(label, a, b):
    print("\n=== diff %s ===" % label)
    for line in difflib.unified_diff(a.splitlines(), b.splitlines(), "baseline", label,
                                     lineterm="", n=1):
        print(line)
    ch = [l for l in difflib.unified_diff(a.splitlines(), b.splitlines(), lineterm="", n=0)
          if l.startswith(("+", "-")) and not l.startswith(("+++", "---"))]
    print("==> %s 改动行数 = %d" % (label, len(ch)))
    return len(ch)


# ---------- A) syscall_event_bridge.c：与 Exp-6 逐字同的 mode 守卫 ----------
seb = load(LOCAL_SEB, SEB_MD5)

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
SEB_BLOCK = """/* ===== EXP6(§6.599)：handler 体三支单步隔离 =====
 * ksu_exp6_mode: 0=全开(＝Exp-1 基线) 1=只留 sucompat 2=只留 ksud 3=只留 sulog
 *                4=三支全摘(≈Exp-5' noop，本谱系自洽对照；§6.601 已实证：活)
 */
unsigned ksu_exp6_mode = 0;
module_param(ksu_exp6_mode, uint, 0);

"""

for a in (ANCHOR_FN, OLD_KSUD, OLD_SULOG, OLD_SUCOMPAT):
    if seb.count(a) != 1:
        raise SystemExit("!! [seb] 锚点缺失或非唯一(count=%d)：%s" % (seb.count(a), a[:100]))

seb2 = seb.replace(ANCHOR_FN, SEB_BLOCK + ANCHOR_FN, 1)
seb2 = seb2.replace(OLD_KSUD, NEW_KSUD, 1)
seb2 = seb2.replace(OLD_SULOG, NEW_SULOG, 1)
seb2 = seb2.replace(OLD_SUCOMPAT, NEW_SUCOMPAT, 1)
if "#include <linux/module.h>" not in seb2:
    inc = "#include \"klog.h\" // IWYU pragma: keep"
    if inc not in seb2:
        raise SystemExit("!! [seb] include 锚点缺失")
    seb2 = seb2.replace(inc, "#include <linux/module.h>\n" + inc, 1)

# ---------- B) sucompat.c ----------
sc = load(LOCAL_SC, SC_MD5)
sc0 = sc          # ★留一份未改动的（下面 sc 会被反复重绑，别拿它当"改前"）

# B-① 清理 63 行重复的 path[0] = 0;（建树时的非幂等残留）
lines = sc.split("\n")
dup_idx = [i for i, l in enumerate(lines) if l.strip().startswith("path[0] = 0;")]
print("==> [B-①] `path[0] = 0;` 命中行数 = %d（期望 63，且必须连续）" % len(dup_idx))
if len(dup_idx) != 63:
    raise SystemExit("!! 重复行数不是 63，拒绝清理（基线可能已变，先核对）")
if dup_idx != list(range(dup_idx[0], dup_idx[0] + 63)):
    raise SystemExit("!! 这 63 行不连续（%d..%d），拒绝清理" % (dup_idx[0], dup_idx[-1]))
keep = lines[dup_idx[0]]
lines = lines[:dup_idx[0]] + [keep] + lines[dup_idx[-1] + 1:]
sc = "\n".join(lines)
print("==> [B-①] 已清理为 1 行；现 `.strip().startswith('path[0] = 0;')` 计数 = %d"
      % sum(1 for l in lines if l.strip().startswith("path[0] = 0;")))

# B-② 串行闸声明块
SC_ANCHOR = "bool ksu_su_compat_enabled __read_mostly = true;"
SC_BLOCK = """

/* ===== EXP-8(§6.609)：把并发拍平 —— handler body 同一时刻只允许一个线程 =====
 * 触发这一发的读数：Exp-6f 把 decline 次数压到 1/3.65（727→199 次/s），死亡时间只
 * 从 19.50 s 挪到 20.75 s（+7.7%）⇒ 不是"每次调用累积损伤"；Exp-6g 压到 0.2 次/s
 * 活过 1384 s ⇒ 最自洽的模型是「≥ ~200 次/秒 时某个锁/状态的交错概率饱和」。
 * 八发里从没有哪一发回答过"同一时刻只进一个"（6d=全不进 / 6f,6g=少进）。
 *
 * ksu_exp6_serial=1 ⇒ 入口 atomic_cmpxchg 抢一个**全局**位：
 *   抢不到 ⇒ `return ksu_orig_syscall_table[orig_nr](regs)`
 *            （与 Exp-6d cut=1 逐字同形，那条路已实证 ≥193.5 s 无害）
 *   抢到   ⇒ 走完 inner，出口**无条件**释放。
 * ★默认 0 ⇒ 外层 `likely(!ksu_exp6_serial)` 短路，连原子操作都不做，行为与基线逐字同。
 * ★真跑业务的窗口别开：并发 su 会被偶发丢掉（重试即可）。命中路径本来就稀少。
 * ★见证：`KSUBEAT SER enter= skip=` 只打 4 次；`skip>0` 本身即"并发发生过、闸真拦到"。
 */
unsigned ksu_exp6_serial = 0;
module_param(ksu_exp6_serial, uint, 0644);
static atomic_t ksu_serial_busy = ATOMIC_INIT(0);
unsigned long ksu_serial_entered = 0;
unsigned long ksu_serial_skipped = 0;
"""
if sc.count(SC_ANCHOR) != 1:
    raise SystemExit("!! [B-②] 锚点缺失或非唯一(count=%d)" % sc.count(SC_ANCHOR))
sc = sc.replace(SC_ANCHOR, SC_ANCHOR + SC_BLOCK, 1)

# B-③ inner/包装：改名 + 在原位置之后插入同名的串行闸包装
INNER_OLD = "static long ksu_handle_execve_sucompat_common(const char __user **filename_user,"
if sc.count(INNER_OLD) != 1:
    raise SystemExit("!! [B-③] inner 签名锚点缺失或非唯一(count=%d)" % sc.count(INNER_OLD))
i0 = sc.find(INNER_OLD)
j0 = sc.find("\n{\n", i0)
if j0 < 0:
    raise SystemExit("!! [B-③] 找不到函数体起始")
j0 += 1
k0 = sc.find("\n}\n", j0)          # 列 0 的收尾大括号 ＝ 函数结束
if k0 < 0:
    raise SystemExit("!! [B-③] 找不到函数收尾大括号")
sc = sc[:i0] + INNER_OLD.replace("sucompat_common", "sucompat_inner") + sc[i0 + len(INNER_OLD):]
# 重新定位（长度未变，但保守起见重找）
i0 = sc.find(INNER_OLD.replace("sucompat_common", "sucompat_inner"))
k0 = sc.find("\n}\n", sc.find("\n{\n", i0) + 1) + 2

WRAPPER = """

/* ===== EXP-8 串行闸包装：只有抢到全局位的那一个线程能进 inner ===== */
static long ksu_handle_execve_sucompat_common(const char __user **filename_user,
                                              const char __user *const __user *argv_user,
                                              unsigned long envp, bool execveat, int orig_nr,
                                              struct pt_regs *regs)
{
    long r;

    if (likely(!ksu_exp6_serial))
        return ksu_handle_execve_sucompat_inner(filename_user, argv_user, envp, execveat,
                                                orig_nr, regs);

    if (atomic_cmpxchg(&ksu_serial_busy, 0, 1) != 0) {
        ksu_serial_skipped++;
        if (ksu_serial_skipped == 1 || ksu_serial_skipped == 100 ||
            ksu_serial_skipped == 1000 || ksu_serial_skipped == 10000)
            pr_info("KSUBEAT SER skip=%lu enter=%lu pid=%d uid=%u\\n", ksu_serial_skipped,
                    ksu_serial_entered, current->pid, current_uid().val);
        return ksu_orig_syscall_table[orig_nr](regs);
    }

    ksu_serial_entered++;
    if (ksu_serial_entered == 1 || ksu_serial_entered == 100 ||
        ksu_serial_entered == 1000 || ksu_serial_entered == 10000)
        pr_info("KSUBEAT SER enter=%lu skip=%lu pid=%d uid=%u\\n", ksu_serial_entered,
                ksu_serial_skipped, current->pid, current_uid().val);

    r = ksu_handle_execve_sucompat_inner(filename_user, argv_user, envp, execveat, orig_nr, regs);

    atomic_set(&ksu_serial_busy, 0);
    return r;
}
"""
sc = sc[:k0] + WRAPPER + sc[k0:]

# B-④ 保证 atomic_t 可见
if "#include <linux/atomic.h>" not in sc:
    ta = "#include <linux/types.h>"
    if sc.count(ta) != 1:
        raise SystemExit("!! [B-④] types.h 锚点缺失或非唯一")
    sc = sc.replace(ta, ta + "\n#include <linux/atomic.h>", 1)

# B-⑤ 自检
checks = {
    "inner 定义": sc.count("static long ksu_handle_execve_sucompat_inner("),
    "包装定义": sc.count("static long ksu_handle_execve_sucompat_common("),
    "cmpxchg": sc.count("atomic_cmpxchg(&ksu_serial_busy, 0, 1)"),
    "释放": sc.count("atomic_set(&ksu_serial_busy, 0)"),
    "enter++": sc.count("ksu_serial_entered++"),
    "skip++": sc.count("ksu_serial_skipped++"),
    "SER 打印": sc.count('pr_info("KSUBEAT SER'),   # ★只数真打印（注释里也提到这个串）
    "原子头": sc.count("#include <linux/atomic.h>"),
}
print("\n==> 自检:", checks)
exp = {"inner 定义": 1, "包装定义": 1, "cmpxchg": 1, "释放": 1,
       "enter++": 1, "skip++": 1, "SER 打印": 2, "原子头": 1}
if checks != exp:
    raise SystemExit("!! 自检不符，期望 %s" % exp)
# 两个调用者必须仍然调到"包装"这个名字（原先就调 `..._common(`，包装已占同名 ⇒ 天然成立）：
#   1 处包装定义 + 2 处调用点 ＝ 3
n_common = sc.count("ksu_handle_execve_sucompat_common(")
print("==> 调用点自检：`..._common(` 出现 %d 次（期望 3＝1 定义＋2 调用）" % n_common)
if n_common != 3:
    raise SystemExit("!! 调用点异常：期望 3，实得 %d" % n_common)
for need in ("PT_REGS_PARM2(regs)", "PT_REGS_PARM3(regs)"):
    if need not in sc:
        raise SystemExit("!! 调用者参数表达式丢失：%s" % need)

seb_b = seb2.encode()
sc_b = sc.encode()
print("\n==> A %d -> %d B  md5=%s" % (len(seb.encode()), len(seb_b), md5b(seb_b)))
print("==> B %d -> %d B  md5=%s" % (len(sc0.encode()), len(sc_b), md5b(sc_b)))

diff("seb", seb, seb2)
diff("sucompat", load(LOCAL_SC, SC_MD5), sc)

if not APPLY:
    # 预览件：把打完补丁的两份源码落盘，供人肉复核（不碰远端）
    open(r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/_preview_serial_seb.c","w",
         encoding="utf-8",newline="\n").write(seb2)
    open(r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/_preview_serial_sucompat.c","w",
         encoding="utf-8",newline="\n").write(sc)
    print("\n==> 预览模式：未碰远端。已落预览件到 kmod/hermes_src/_preview_serial_*.c；确认后可加 --apply。")
    sys.exit(0)

print("\n==> ping:", bool(api.ping()))
cur = api.exec("md5sum %s %s %s" % (SEB, SC, KO_REMOTE), timeout=120)
got = dict((l.split()[1], l.split()[0]) for l in cur.stdout.splitlines() if len(l.split()) >= 2)
print("==> 远端现状:", got)
for p, want, name in ((SEB, SEB_MD5, "seb"), (SC, SC_MD5, "sucompat")):
    if got.get(p) != want:
        raise SystemExit("!! 远端 %s 基线不符（%s != %s），拒绝改动。" % (name, got.get(p), want))
if got.get(KO_REMOTE) != RC80_MD5:
    raise SystemExit("!! 远端 kernelsu.ko 不是 rc80（%s），拒绝（免得备份错件）" % got.get(KO_REMOTE))
for path, bk in ((SEB, BK_SEB), (SC, BK_SC)):
    b = api.exec("cp -f %s %s && md5sum %s" % (path, bk, bk), timeout=120)
    print("==> 备份 %s md5 = %s" % (bk, b.stdout.split()[0] if b.stdout.split() else "?"))
rc = api.exec("cp -f %s %s && md5sum %s" % (KO_REMOTE, KO_RC80_BK, KO_RC80_BK), timeout=180)
print("==> rc80 ko 备份:", rc.stdout.strip())


def restore_one(path, bk, want, name):
    r = api.exec("cp -f %s %s && md5sum %s" % (bk, path, path), timeout=120)
    g = r.stdout.split()[0] if r.stdout.split() else ""
    ok = (g == want)
    print("==> 还原 %-9s md5=%s %s" % (name, g, "OK" if ok else "!!!MISMATCH"))
    return ok


def upload(path, data):
    b64 = base64.b64encode(data).decode()
    chunks = [b64[i:i + 900] for i in range(0, len(b64), 900)]
    cmds = [": > %s.b64" % path]
    for c in chunks:
        cmds.append("printf %%s %s >> %s.b64" % (c, path))
    cmds += ["base64 -d %s.b64 > %s" % (path, path), "rm -f %s.b64" % path, "md5sum %s" % path]
    up = api.exec("\n".join(cmds), timeout=300)
    g = up.stdout.split()[0] if up.stdout.split() else ""
    print("==> 上传 %s md5=%s %s" % (path, g, "OK" if g == md5b(data) else "!!!MISMATCH"))
    return g == md5b(data)


ok = False
r1 = r2 = False
try:
    if not upload(SEB, seb_b):
        raise SystemExit("!! A 上传不符，中止（将还原）")
    if not upload(SC, sc_b):
        raise SystemExit("!! B 上传不符，中止（将还原）")

    make = ("cd %s && make -C %s M=%s src=%s CONFIG_KSU=m ARCH=arm64 "
            "CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld AR=llvm-ar "
            "NM=llvm-nm OBJCOPY=llvm-objcopy STRIP=llvm-strip "
            'KCFLAGS="-include /home/lucy/ksu_compat54.h" '
            "modules -j32 > %s 2>&1; echo EXITCODE=$?") % (KDIR, KDIR, MDIR, MDIR, LOG)
    print("==> 编译中（可能几分钟）...")
    br = api.exec(make, timeout=900)
    print("==> build rc:", br.exit_code, "tail:", br.stdout.strip()[-80:])
    if "EXITCODE=0" not in br.stdout:
        for ln in api.read(LOG).splitlines()[-25:]:
            print("   ", ln)
        raise SystemExit("!! 编译未成功")

    cp = api.exec("cp -f %s %s && ls -l %s && md5sum %s" % (KO_REMOTE, KO_HOME, KO_HOME, KO_HOME),
                  timeout=180)
    print("==> ko cp:", cp.stdout.strip())
    data = api.read_bytes("kernelsu_serial.ko")
    print("==> 拉回字节数:", len(data), "md5:", md5b(data))
    if len(data) > 100000:
        open(LOCAL_KO, "wb").write(data)
        print("==> 已写本地:", LOCAL_KO)
        ok = True
    else:
        print("!! ko 尺寸异常，未写入")
finally:
    print("\n==> 还原远端源码 ...")
    r1 = restore_one(SEB, BK_SEB, SEB_MD5, "seb")
    r2 = restore_one(SC, BK_SC, SC_MD5, "sucompat")
    rb = api.exec("cp -f %s %s && md5sum %s" % (KO_RC80_BK, KO_REMOTE, KO_REMOTE), timeout=180)
    print("==> 远端 kernelsu.ko 还原:", rb.stdout.strip())

print("\n==> 结果:", "SERIAL_KO_OK" if (ok and r1 and r2) else "FAILED_SEE_ABOVE")
