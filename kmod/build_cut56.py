#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Exp-10 构建（§6.613）：同一 ko 同时支持 cut=5(对照) / cut=6(新切口)。

第 18 枪结论（§6.612）：cut=1（函数开头 return）活，cut=5（名单判定之后 return）仍 18.28 s 死
⇒ 凶手在两者之间的三行：execveat && flags / !filename_user / ksu_is_allow_uid_for_current()。
cut=6 ＝ 在 `filename_user` 检查之后、`ksu_is_allow_uid_for_current()` **之前** return orig，
        即前两行检查保留、名单判定不执行。
★cut=1 已经在「execveat 检查之前」切过且活了，所以 cut=6 必须切在名单判定之前、
  而不是 execveat 之前（那会是重复空枪）——这是 21:4x 纠正过的定义。

两个切口互斥、由 ksu_exp6_cut 选；同一 ko 可跑 5 和 6 ⇒ 消除 ko 差异这个共变源。
判据与结局写死在 kmod/w1226_cut6_plan.md。

用法：python build_cut56.py            # 预览（0 接触）
      python build_cut56.py --apply    # 备份+上传+编译+拉回+无条件还原
"""
import sys, hashlib, base64, difflib

sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import from_config

SEB = "/root/k/ksu/kernel/hook/syscall_event_bridge.c"
SC = "/root/k/ksu/kernel/feature/sucompat.c"
BK_SEB = "/tmp/seb_cut56_orig.c"
BK_SC = "/tmp/sucompat_cut56_orig.c"
MDIR = "/root/k/ksu/kernel"
KDIR = "/root/k/nothing_sm7325_v_mr"
LOG = "/home/lucy/cut56_build.log"
KO_REMOTE = "/root/k/ksu/kernel/kernelsu.ko"
KO_RC80_BK = "/home/lucy/kernelsu_rc80_backup.ko"
KO_HOME = "/home/lucy/kernelsu_cut56.ko"
LOCAL_SEB = r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/seb_remote_now.c"
LOCAL_SC = r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/sucompat_remote_now.c"
LOCAL_KO = r"G:/项目/Windows管理/usb/临时root/kmod/kernelsu_cut56.ko"
SEB_MD5 = "26dd9a0af093d31d04ec73484a530fee"
SC_MD5 = "0a305171e7b5b1bb338862ee9639e974"
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


# ---------- A) syscall_event_bridge.c：与 Exp-6/6b 同一套 mode 守卫 ----------
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

# ---------- B) sucompat.c：quiet 总闸 + 两个 cut ----------
sc = load(LOCAL_SC, SC_MD5)

SC_ANCHOR = "bool ksu_su_compat_enabled __read_mostly = true;"
SC_BLOCK = """

/* ===== EXP6b(§6.599)：sucompat 热路径打印总闸 =====
 * ksu_exp6_quiet=1 ⇒ 把全部 KSUBEAT S… 热路径打印静音（SD0..SD5 / SU0..SU4，共 17 处）。
 * ★只静音：逻辑一行不改、往真 execve 里的调用帧一层不减 ⇒ 「打印/console 串行」vs
 *   「逻辑/栈深度」的判别器（§6.599 已判：打印不是死因）。
 */
unsigned ksu_exp6_quiet = 0;
module_param(ksu_exp6_quiet, uint, 0644);
#define ksu_hp_pr(fmt, ...) do { if (unlikely(!ksu_exp6_quiet)) pr_info(fmt, ##__VA_ARGS__); } while (0)

/* ===== EXP6d(§6.602)：sucompat 内部两处切口 =====
 * ksu_exp6_cut: 0=不切 1=入口即退(连 execveat 检查/名单/路径都不做) 2=判据段后即退(SU0 之前)
 * 见证：切口会把 sucompat 打印全灭掉 ⇒ 自带只打 3 次(hit=1/100/1000)的计数器，
 *       另有全局 hits 可在 ELF 符号表核对，避免把"没打印"读成"没执行"。
 */
unsigned ksu_exp6_cut = 0;
module_param(ksu_exp6_cut, uint, 0644);
unsigned ksu_exp6_cut1_hits = 0;
unsigned ksu_exp6_cut2_hits = 0;
unsigned ksu_exp6_cut5_hits = 0;
unsigned ksu_exp6_cut6_hits = 0;
"""
if sc.count(SC_ANCHOR) != 1:
    raise SystemExit("!! [sc] 锚点缺失或非唯一(count=%d)" % sc.count(SC_ANCHOR))
sc2 = sc.replace(SC_ANCHOR, SC_ANCHOR + SC_BLOCK, 1)

N_INFO = sc2.count('pr_info("KSUBEAT S')
N_WARN = sc2.count('pr_warn("KSUBEAT S')
print("==> 待静音：pr_info(\"KSUBEAT S =%d  pr_warn(\"KSUBEAT S =%d（期望 16 / 1）" % (N_INFO, N_WARN))
if (N_INFO, N_WARN) != (16, 1):
    raise SystemExit("!! 静音点数量不符（期望 16/1），拒绝打补丁")
sc2 = sc2.replace('pr_info("KSUBEAT S', 'ksu_hp_pr("KSUBEAT S')
sc2 = sc2.replace('pr_warn("KSUBEAT S', 'ksu_hp_pr("KSUBEAT S')

# --- cut=1：入口即退。锚点＝common 函数里第一处真正的检查（其前只有 63 行 path[0]=0） ---
CUT1_ANCHOR = ("    if (execveat && ((int)PT_REGS_SYSCALL_PARM1(regs) != AT_FDCWD || "
               "(int)PT_REGS_PARM5(regs) != 0))\n")
CUT1_BLOCK = """    if (unlikely(ksu_exp6_cut == 1)) {
        /* 入口即退：栈帧已建、path[0]=0 已写，之外什么都没做 */
        ksu_exp6_cut1_hits++;
        if (ksu_exp6_cut1_hits == 1 || ksu_exp6_cut1_hits == 100 || ksu_exp6_cut1_hits == 1000)
            pr_info("KSUBEAT CUT1 hit=%u pid=%d uid=%u\\n", ksu_exp6_cut1_hits, current->pid,
                    current_uid().val);
        return ksu_orig_syscall_table[orig_nr](regs);
    }

"""
if sc2.count(CUT1_ANCHOR) != 1:
    raise SystemExit("!! [cut1] 锚点缺失或非唯一(count=%d)" % sc2.count(CUT1_ANCHOR))
sc2 = sc2.replace(CUT1_ANCHOR, CUT1_BLOCK + CUT1_ANCHOR, 1)

# --- cut=2：判据段后即退（原 decline_only 切口）。锚点＝SU0（已被静音宏包住） ---
CUT2_ANCHOR = '    ksu_hp_pr("KSUBEAT SU0 su found:'
CUT2_BLOCK = """    if (unlikely(ksu_exp6_cut == 2)) {
        /* 判据段后即退：uid 名单、路径拷贝、memcmp 都做过了，但绝不进 grant 段 */
        ksu_exp6_cut2_hits++;
        if (ksu_exp6_cut2_hits == 1 || ksu_exp6_cut2_hits == 100 || ksu_exp6_cut2_hits == 1000)
            pr_info("KSUBEAT CUT2 hit=%u pid=%d uid=%u path=[%s]\\n", ksu_exp6_cut2_hits,
                    current->pid, current_uid().val, path);
        goto do_orig_execve;
    }

"""
if sc2.count(CUT2_ANCHOR) != 1:
    raise SystemExit("!! [cut2] 锚点缺失或非唯一(count=%d)" % sc2.count(CUT2_ANCHOR))
sc2 = sc2.replace(CUT2_ANCHOR, CUT2_BLOCK + CUT2_ANCHOR, 1)

# --- cut=5 / cut=6：切在「名单判定之前」与「名单判定之后」两个紧邻位置 ---
# cut=6：名单判定 **不执行**（execveat / filename_user 两行检查已跑完）
# cut=5：名单判定 **已执行**（作为 if 条件），跳过 SD1 打印 / goto / 标签体 / 尾部 return 形态
# ⇒ 两者互斥、由 ksu_exp6_cut 选；与 cut=1（函数开头 return，活）构成三点对照。
ANCHOR56 = "    if (!ksu_is_allow_uid_for_current(current_uid().val)) {\n"
CUT6_BLOCK = """    if (unlikely(ksu_exp6_cut == 6)) {
        /* 保留 execveat && flags 检查、!filename_user 检查；
         * 跳过 ksu_is_allow_uid_for_current() 这个调用本身 */
        ksu_exp6_cut6_hits++;
        if (ksu_exp6_cut6_hits == 1 || ksu_exp6_cut6_hits == 100 || ksu_exp6_cut6_hits == 1000)
            pr_info("KSUBEAT CUT6 hit=%u pid=%d uid=%u\\n", ksu_exp6_cut6_hits, current->pid,
                    current_uid().val);
        return ksu_orig_syscall_table[orig_nr](regs);
    }

"""
CUT5_BLOCK = """    if (unlikely(ksu_exp6_cut == 5)) {
        /* 名单判定已在上面的 if 条件里跑完；这里立刻 return orig，
         * 跳过 SD1 打印 / goto do_orig_execve / 标签体 / 函数尾的 return 形态 */
        ksu_exp6_cut5_hits++;
        if (ksu_exp6_cut5_hits == 1 || ksu_exp6_cut5_hits == 100 || ksu_exp6_cut5_hits == 1000)
            pr_info("KSUBEAT CUT5 hit=%u pid=%d uid=%u\\n", ksu_exp6_cut5_hits, current->pid,
                    current_uid().val);
        return ksu_orig_syscall_table[orig_nr](regs);
    }
"""
if sc2.count(ANCHOR56) != 1:
    raise SystemExit("!! [cut56] 锚点缺失或非唯一(count=%d)" % sc2.count(ANCHOR56))
sc2 = sc2.replace(ANCHOR56, CUT6_BLOCK + ANCHOR56 + CUT5_BLOCK, 1)

# --- /proc/ksu_ser 拉取式见证（与 w1223 采集器同名，不经 dmesg） ---
INC_ANCHOR = "#include <linux/fs.h>"
if sc2.count(INC_ANCHOR) != 1:
    raise SystemExit("!! [D] fs.h 锚点异常")
sc2 = sc2.replace(INC_ANCHOR, INC_ANCHOR + "\n#include <linux/proc_fs.h>", 1)

INIT_ANCHOR = "void __init ksu_sucompat_init()"
if sc2.count(INIT_ANCHOR) != 1:
    raise SystemExit("!! [D] init 锚点异常")
D_BLOCK = """/* ===== EXP-9/10：拉取式见证（第 16/17/18 枪已证明可靠） ===== */
static ssize_t ksu_cut56_read(struct file *filp, char __user *ubuf, size_t cnt, loff_t *ppos)
{
    char line[160];
    int n;

    if (*ppos > 0)
        return 0;
    n = scnprintf(line, sizeof(line),
                  "SERD CUT56 cut=%u hits5=%lu hits6=%lu quiet=%u\\n",
                  ksu_exp6_cut, (unsigned long)ksu_exp6_cut5_hits,
                  (unsigned long)ksu_exp6_cut6_hits, ksu_exp6_quiet);
    if ((size_t)n < cnt)
        cnt = (size_t)n;
    if (copy_to_user(ubuf, line, cnt))
        return -EFAULT;
    *ppos += (loff_t)cnt;
    return (ssize_t)cnt;
}

static const struct file_operations ksu_cut56_fops = {
    .owner = THIS_MODULE,
    .read = ksu_cut56_read,
    .llseek = default_llseek,
};

"""
sc2 = sc2.replace(INIT_ANCHOR, D_BLOCK + INIT_ANCHOR, 1)
M5 = '    pr_info("KSUBEAT M5 enter sucompat_init\\n");'
if sc2.count(M5) != 1:
    raise SystemExit("!! [D] M5 锚点异常")
M5_ADD = """
    {
        struct proc_dir_entry *pe = proc_create("ksu_ser", 0444, NULL, &ksu_cut56_fops);

        pr_info("KSUBEAT CUT56 proc=%s\\n", pe ? "ok" : "FAIL");
    }"""
sc2 = sc2.replace(M5, M5 + M5_ADD, 1)


for need in ('ksu_exp6_cut1_hits', 'ksu_exp6_cut2_hits', 'KSUBEAT CUT1', 'KSUBEAT CUT2',
             'ksu_exp6_cut5_hits', 'ksu_exp6_cut6_hits', 'KSUBEAT CUT5', 'KSUBEAT CUT6',
             'ksu_cut56_read', 'proc_create'):
    if need not in sc2:
        raise SystemExit("!! 自检失败：%s 不在产物源码里" % need)

seb_b = seb2.encode()
sc_b = sc2.encode()
print("\n==> A %d -> %d B  md5=%s" % (len(seb.encode()), len(seb_b), md5b(seb_b)))
print("==> B %d -> %d B  md5=%s" % (len(sc.encode()), len(sc_b), md5b(sc_b)))

diff("seb", seb, seb2)
diff("sucompat", sc, sc2)

if not APPLY:
    open(r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/_preview_cut56_seb.c", "w",
         encoding="utf-8", newline="\n").write(seb2)
    open(r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/_preview_cut56_sucompat.c", "w",
         encoding="utf-8", newline="\n").write(sc2)
    print("\n==> 预览模式：未碰远端。已落 _preview_cut56_*.c；确认后可加 --apply。")
    sys.exit(0)

print("\n==> ping:", bool(api.ping()))
for path, bk, want, name in ((SEB, BK_SEB, SEB_MD5, "seb"), (SC, BK_SC, SC_MD5, "sucompat")):
    cur = api.exec("md5sum %s" % path, timeout=120)
    got = cur.stdout.split()[0] if cur.stdout.split() else ""
    print("==> 远端 %s 现状 md5 = %s" % (name, got))
    if got != want:
        raise SystemExit("!! 远端 %s 基线不符（期望 %s），拒绝改动。" % (name, want))
    b = api.exec("cp -f %s %s && md5sum %s" % (path, bk, bk), timeout=120)
    print("==> 备份 %s md5 = %s" % (bk, b.stdout.split()[0] if b.stdout.split() else "?"))

chk = api.exec("md5sum %s" % KO_REMOTE, timeout=120)
got_ko = chk.stdout.split()[0] if chk.stdout.split() else ""
print("==> 远端 kernelsu.ko 现状:", got_ko)
if got_ko != "98bf405273e8652cdb7fffcc3fe42dc2":
    raise SystemExit("!! 远端 kernelsu.ko 不是 rc80，拒绝（免得备份错件）")
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
    got = up.stdout.split()[0] if up.stdout.split() else ""
    print("==> 上传 %s md5=%s %s" % (path, got, "OK" if got == md5b(data) else "!!!MISMATCH"))
    return got == md5b(data)


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
    data = api.read_bytes("kernelsu_cut56.ko")
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

print("\n==> 结果:", "CUT56_KO_OK" if (ok and r1 and r2) else "FAILED_SEE_ABOVE")
