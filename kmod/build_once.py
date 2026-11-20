#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Exp-8c 构建（§6.611）：「一次性进入」—— 深路严格只跑 1 次。

要回答：把深路次数从 46~727 次/s 压到恰好 1 次，还会不会 ~19.5 s 死？
  第 16 枪给出「门槛+引信」形状，但不能区分 (甲)按次数累积 / (乙)第一次深路就武装了什么。
  若是 (乙) ⇒ 触发点收敛到第一次深路那段代码 ⇒ 可能是可修的 bug ⇒ 全速 su 才有戏。
  若是 (甲) ⇒ 确认「能活的速率正好是把 su 废掉的速率」⇒ 可用区间为空盖棺。
判据与结局写死在 kmod/w1218_exp8c_once_plan.md。

补丁链：本文件由 build_serial2.py 逐字派生（A/B/D 三块**不改一个字符**），只做：
  E-① SC_BLOCK 末尾加 once 声明（ksu_exp6_once / ksu_once_done / 两个计数）
  E-② WRAPPER 的 _common 开头加 once 门，放在串行闸**之前**
  E-③ /proc/ksu_ser 的 SERD 行扩展 once 三字段
  E-④ 自检项扩展
  ★本发 args 不开 ksu_exp6_serial ⇒ 串行闸默认短路，深路次数严格 = 1。

用法：python build_once.py            # 预览（0 接触）
      python build_once.py --apply    # 备份+上传+编译+拉回+无条件还原
"""
import sys, hashlib, base64, difflib

sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import from_config

SEB = "/root/k/ksu/kernel/hook/syscall_event_bridge.c"
SC = "/root/k/ksu/kernel/feature/sucompat.c"
BK_SEB = "/tmp/seb_once_orig.c"
BK_SC = "/tmp/sucompat_once_orig.c"
MDIR = "/root/k/ksu/kernel"
KDIR = "/root/k/nothing_sm7325_v_mr"
LOG = "/home/lucy/once_build.log"
KO_REMOTE = "/root/k/ksu/kernel/kernelsu.ko"
KO_RC80_BK = "/home/lucy/kernelsu_rc80_backup.ko"
KO_HOME = "/home/lucy/kernelsu_once.ko"
LOCAL_SEB = r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/seb_remote_now.c"
LOCAL_SC = r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/sucompat_remote_now.c"
LOCAL_KO = r"G:/项目/Windows管理/usb/临时root/kmod/kernelsu_once.ko"
PREV_SEB = r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/_preview_once_seb.c"
PREV_SC = r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/_preview_once_sucompat.c"
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


# ==================== A) syscall_event_bridge.c（与 Exp-8 逐字同） ====================
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

# ==================== B) sucompat.c：清 63 行 + 串行闸（与 Exp-8 逐字同） ====================
sc = load(LOCAL_SC, SC_MD5)
sc0 = sc

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
print("==> [B-①] 已清理为 1 行；现计数 = %d"
      % sum(1 for l in lines if l.strip().startswith("path[0] = 0;")))

SC_ANCHOR = "bool ksu_su_compat_enabled __read_mostly = true;"
SC_BLOCK = """

/* ===== EXP-8(§6.609)：把并发拍平 —— handler body 同一时刻只允许一个线程 =====
 * ksu_exp6_serial=1 ⇒ 入口 atomic_cmpxchg 抢一个**全局**位：
 *   抢不到 ⇒ `return ksu_orig_syscall_table[orig_nr](regs)`
 *            （与 Exp-6d cut=1 逐字同形，那条路已实证 ≥193.5 s 无害）
 *   抢到   ⇒ 走完 inner，出口**无条件**释放。
 * ★默认 0 ⇒ 外层 `likely(!ksu_exp6_serial)` 短路，连原子操作都不做，行为与基线逐字同。
 */
unsigned ksu_exp6_serial = 0;
module_param(ksu_exp6_serial, uint, 0644);
static atomic_t ksu_serial_busy = ATOMIC_INIT(0);
unsigned long ksu_serial_entered = 0;
unsigned long ksu_serial_skipped = 0;

/* ===== EXP-8c(§6.611)：一次性进入 =====
 * ksu_exp6_once=1 ⇒ _common 入口抢一次 ksu_once_done，只有第一个线程进 inner，
 * 之后所有 execve 直接 return orig ⇒ 深路次数严格 = 1。
 * ★与第 16 枪唯一的语义增量；默认 0 ⇒ 与 serial2 逐字同。
 */
unsigned ksu_exp6_once = 0;
module_param(ksu_exp6_once, uint, 0644);
static atomic_t ksu_once_done = ATOMIC_INIT(0);
unsigned long ksu_once_entered = 0;
unsigned long ksu_once_skipped = 0;
"""
if sc.count(SC_ANCHOR) != 1:
    raise SystemExit("!! [B-②] 锚点缺失或非唯一(count=%d)" % sc.count(SC_ANCHOR))
sc = sc.replace(SC_ANCHOR, SC_ANCHOR + SC_BLOCK, 1)

INNER_OLD = "static long ksu_handle_execve_sucompat_common(const char __user **filename_user,"
if sc.count(INNER_OLD) != 1:
    raise SystemExit("!! [B-③] inner 签名锚点缺失或非唯一(count=%d)" % sc.count(INNER_OLD))
i0 = sc.find(INNER_OLD)
j0 = sc.find("\n{\n", i0)
if j0 < 0:
    raise SystemExit("!! [B-③] 找不到函数体起始")
j0 += 1
k0 = sc.find("\n}\n", j0)
if k0 < 0:
    raise SystemExit("!! [B-③] 找不到函数收尾大括号")
sc = sc[:i0] + INNER_OLD.replace("sucompat_common", "sucompat_inner") + sc[i0 + len(INNER_OLD):]
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

    /* EXP-8c：一次性进入门（放在串行闸之前 ⇒ 深路严格 1 次） */
    if (unlikely(ksu_exp6_once)) {
        if (atomic_cmpxchg(&ksu_once_done, 0, 1) != 0) {
            ksu_once_skipped++;
            return ksu_orig_syscall_table[orig_nr](regs);
        }
        ksu_once_entered++;
        return ksu_handle_execve_sucompat_inner(filename_user, argv_user, envp, execveat,
                                                orig_nr, regs);
    }

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

if "#include <linux/atomic.h>" not in sc:
    ta = "#include <linux/types.h>"
    if sc.count(ta) != 1:
        raise SystemExit("!! [B-④] types.h 锚点缺失或非唯一")
    sc = sc.replace(ta, ta + "\n#include <linux/atomic.h>", 1)

checks = {
    "inner 定义": sc.count("static long ksu_handle_execve_sucompat_inner("),
    "包装定义": sc.count("static long ksu_handle_execve_sucompat_common("),
    "cmpxchg": sc.count("atomic_cmpxchg(&ksu_serial_busy, 0, 1)"),
    "释放": sc.count("atomic_set(&ksu_serial_busy, 0)"),
    "enter++": sc.count("ksu_serial_entered++"),
    "skip++": sc.count("ksu_serial_skipped++"),
    "SER 打印": sc.count('pr_info("KSUBEAT SER'),
    "原子头": sc.count("#include <linux/atomic.h>"),
}
print("\n==> 自检:", checks)
exp = {"inner 定义": 1, "包装定义": 1, "cmpxchg": 1, "释放": 1,
       "enter++": 1, "skip++": 1, "SER 打印": 2, "原子头": 1}
if checks != exp:
    raise SystemExit("!! 自检不符，期望 %s" % exp)
n_common = sc.count("ksu_handle_execve_sucompat_common(")
print("==> 调用点自检：`..._common(` 出现 %d 次（期望 3＝1 定义＋2 调用）" % n_common)
if n_common != 3:
    raise SystemExit("!! 调用点异常：期望 3，实得 %d" % n_common)
for need in ("PT_REGS_PARM2(regs)", "PT_REGS_PARM3(regs)"):
    if need not in sc:
        raise SystemExit("!! 调用者参数表达式丢失：%s" % need)

# ==================== D) 拉取式见证 /proc/ksu_ser（本发唯一的增量） ====================
# D-① proc_fs.h
INC_ANCHOR = "#include <linux/fs.h>"
if sc.count(INC_ANCHOR) != 1:
    raise SystemExit("!! [D-①] fs.h 锚点缺失或非唯一(count=%d)" % sc.count(INC_ANCHOR))
if "#include <linux/proc_fs.h>" not in sc:
    sc = sc.replace(INC_ANCHOR, INC_ANCHOR + "\n#include <linux/proc_fs.h>", 1)

# D-② read 回调 + fops（放在 ksu_sucompat_init 之前）
INIT_ANCHOR = "void __init ksu_sucompat_init()"
if sc.count(INIT_ANCHOR) != 1:
    raise SystemExit("!! [D-②] init 锚点缺失或非唯一(count=%d)" % sc.count(INIT_ANCHOR))
SERD_BLOCK = """/* ===== EXP-8b(§6.610)：**拉取式**见证 —— /proc/ksu_ser =====
 * 为什么不用 pr_info：第 15 枪查明 stage 那份内核日志是被过滤的子集（连无条件必打的
 * `KSUBEAT M2/M3/M5` 都不在里面），"打印为 0" 推不出 "路径没跑"。
 * 这里改成 read 时**现算**，PC 侧在 19 秒窗口里 poll —— 不经环形缓冲、不经 stage 抽取。
 * ★只读，不改变任何执行路径；唯一的语义增量是 init 时多建一个 0444 文件。
 */
extern unsigned ksu_exp6_mode;
extern unsigned ksu_hook_mask;

static ssize_t ksu_ser_read(struct file *filp, char __user *ubuf, size_t cnt, loff_t *ppos)
{
    char line[192];
    int n;

    if (*ppos > 0)
        return 0;
    n = scnprintf(line, sizeof(line),
                  "SERD once=%u once_enter=%lu once_skip=%lu serial=%u mode=%u mask=0x%x enter=%lu skip=%lu busy=%d\\n",
                  ksu_exp6_once, ksu_once_entered, ksu_once_skipped,
                  ksu_exp6_serial, ksu_exp6_mode, ksu_hook_mask,
                  ksu_serial_entered, ksu_serial_skipped, atomic_read(&ksu_serial_busy));
    if ((size_t)n < cnt)
        cnt = (size_t)n;
    if (copy_to_user(ubuf, line, cnt))
        return -EFAULT;
    *ppos += (loff_t)cnt;
    return (ssize_t)cnt;
}

static const struct file_operations ksu_ser_fops = {
    .owner = THIS_MODULE,
    .read = ksu_ser_read,
    .llseek = default_llseek,
};

"""
sc = sc.replace(INIT_ANCHOR, SERD_BLOCK + INIT_ANCHOR, 1)

# D-③ 在 init 里建文件，同句把结果打出来（proc 建不出来时至少有个说法；判据仍只认拉到的文件）
M5_ANCHOR = '    pr_info("KSUBEAT M5 enter sucompat_init\\n");'
if sc.count(M5_ANCHOR) != 1:
    raise SystemExit("!! [D-③] M5 锚点缺失或非唯一(count=%d)" % sc.count(M5_ANCHOR))
M5_ADD = M5_ANCHOR + """
    {
        struct proc_dir_entry *pe = proc_create("ksu_ser", 0444, NULL, &ksu_ser_fops);

        pr_info("KSUBEAT SERD proc=%s serial=%u mode=%u mask=0x%x\\n",
                pe ? "ok" : "FAIL", ksu_exp6_serial, ksu_exp6_mode, ksu_hook_mask);
    }"""
sc = sc.replace(M5_ANCHOR, M5_ADD, 1)

# D-④ 自检
dchecks = {
    "proc 头": sc.count("#include <linux/proc_fs.h>"),
    "read 定义": sc.count("static ssize_t ksu_ser_read("),
    "fops": sc.count("static const struct file_operations ksu_ser_fops"),
    "proc_create": sc.count('proc_create("ksu_ser", 0444'),
    "SERD 打印": sc.count('pr_info("KSUBEAT SERD'),
    "SERD 行": sc.count("SERD once=%u once_enter=%lu once_skip=%lu serial=%u mode=%u mask=0x%x enter=%lu skip=%lu busy=%d"),
    "once 声明": sc.count("unsigned ksu_exp6_once = 0;"),
    "once 抢位": sc.count("atomic_cmpxchg(&ksu_once_done, 0, 1)"),
    "once 进": sc.count("ksu_once_entered++"),
    "once 跳": sc.count("ksu_once_skipped++"),
    "extern mode": sc.count("extern unsigned ksu_exp6_mode;"),
    "extern mask": sc.count("extern unsigned ksu_hook_mask;"),
}
print("==> [D] 自检:", dchecks)
dexp = {"proc 头": 1, "read 定义": 1, "fops": 1, "proc_create": 1,
        "SERD 打印": 1, "SERD 行": 1, "extern mode": 1, "extern mask": 1,
        "once 声明": 1, "once 抢位": 1, "once 进": 1, "once 跳": 1}
if dchecks != dexp:
    raise SystemExit("!! [D] 自检不符，期望 %s" % dexp)

seb_b = seb2.encode()
sc_b = sc.encode()
print("\n==> A %d -> %d B  md5=%s" % (len(seb.encode()), len(seb_b), md5b(seb_b)))
print("==> B %d -> %d B  md5=%s" % (len(sc0.encode()), len(sc_b), md5b(sc_b)))

diff("seb", seb, seb2)
diff("sucompat", load(LOCAL_SC, SC_MD5), sc)

if not APPLY:
    open(PREV_SEB, "w", encoding="utf-8", newline="\n").write(seb2)
    open(PREV_SC, "w", encoding="utf-8", newline="\n").write(sc)
    print("\n==> 预览模式：未碰远端。已落预览件 %s / %s；确认后可加 --apply。" % (PREV_SEB, PREV_SC))
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
    data = api.read_bytes("kernelsu_once.ko")
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

print("\n==> 结果:", "ONCE_KO_OK" if (ok and r1 and r2) else "FAILED_SEE_ABOVE")
