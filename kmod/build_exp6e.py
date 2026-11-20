#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Exp-6e 构建（§6.603）：正面打 B 截的首要嫌疑 —— is_sid_match 的慢路。

Exp-6d 已经判掉 A 截（进函数本身就活 ≥193.5 s），凶手落在 B 截。现有三份间接证据齐指慢路：
  1) 代码：cached_su_sid 是 __read_mostly，cache_sid() 里 secctx_to_secid 失败就置 0；
     is_sid_match 见 cached==0 就整段走「__security_secid_to_secctx 分配串 → strncmp → release」。
  2) 日志：Exp-6/6b/6d 三发 dmesg 全有 `Failed to cache kernel su domain SID: -22`（-EINVAL）
     ⇒ 本机策略里没有 u:r:ksu:s0（§6.212⑧）⇒ fast path 永远用不上。
  3) 量级：Exp-6 死前 SD1=822，其中 **uid=0 有 738 行**（uid=2000 的 84 行走 forbid_system_uid，
     根本不进 is_ksu_domain）⇒ 19.5 s 里约 738 次慢路 ≈ 38 次/s。
  4) 形状：无 panic/Oops/调用栈、日志中流截断、PMIC 硬复位 ⇒ 像是锁/内存路径被拖死，不是野指针炸栈。

本发只加一个开关（严格单变量，接 Exp-6 的 shape：mode=1 + quiet=0，19.5 s 死）：
  ksu_exp6_noslow=1 ⇒ is_ksu_domain() 在 cached_su_sid==0 时直接 return false，不进慢路。

★决策不变性（为什么这不是"把 bug 藏起来"）：慢路是拿当前任务的 secctx 串去比 "u:r:ksu:s0"；
  本机没有这个域（secctx_to_secid 都 -22）⇒ 任何任务都不可能匹配 ⇒ 慢路必然返回 false。
  短路返回同一结果 false，**只减工作量、不改判据**。所以：
    活 ⇒ 慢路就是死因（且这就是社区 0x1a 路线在本机可行的补丁方向）
    死 ⇒ 不是它，凶手回到 forbid_system_uid / strncpy_from_user 那一小段（下一发 cut=3 判完）

★见证：noslow 自己带只打 3 次的计数器（hit=1/100/1000）+ 全局 ksu_exp6_noslow_hits，
  保证"确实短路了"是正面证据，而不是靠"没崩"倒推。

改动（三个文件，各自 md5 硬闸 + 无条件还原）：
  A) hook/syscall_event_bridge.c（基线 26dd9a0a…）：与 Exp-6/6b 完全相同的 3 处 mode 守卫。
  B) feature/sucompat.c（基线 0a305171…）：6b 的 quiet 总闸 + 6d 的两个切口（本发都不开）。
  C) selinux/selinux.c（基线 96961886…）：本发的核心 —— ksu_exp6_noslow 参数 + is_ksu_domain() 短路。
     只动 is_ksu_domain()，**不碰 is_sid_match 本体** ⇒ is_zygote()/is_init() 行为一字不改。

用法：python build_exp6e.py            # 预览
     python build_exp6e.py --apply    # 备份+上传+编译+拉回+无条件还原
"""
import sys, hashlib, base64, difflib

sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import from_config

SEB = "/root/k/ksu/kernel/hook/syscall_event_bridge.c"
SC = "/root/k/ksu/kernel/feature/sucompat.c"
SEL = "/root/k/ksu/kernel/selinux/selinux.c"
BK_SEB = "/tmp/seb_exp6e_orig.c"
BK_SC = "/tmp/sucompat_exp6e_orig.c"
BK_SEL = "/tmp/selinux_exp6e_orig.c"
MDIR = "/root/k/ksu/kernel"
KDIR = "/root/k/nothing_sm7325_v_mr"
LOG = "/home/lucy/exp6e_build.log"
KO_REMOTE = "/root/k/ksu/kernel/kernelsu.ko"
KO_RC80_BK = "/home/lucy/kernelsu_rc80_backup.ko"
KO_HOME = "/home/lucy/kernelsu_exp6e.ko"
LOCAL_SEB = r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/seb_remote_now.c"
LOCAL_SC = r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/sucompat_remote_now.c"
LOCAL_SEL = r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/selinux_remote_now.c"
LOCAL_KO = r"G:/项目/Windows管理/usb/临时root/kmod/kernelsu_exp6e.ko"
SEB_MD5 = "26dd9a0af093d31d04ec73484a530fee"
SC_MD5 = "0a305171e7b5b1bb338862ee9639e974"
SEL_MD5 = "96961886a3ffae8a195de77bee7798f8"
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

for need in ('ksu_exp6_cut1_hits', 'ksu_exp6_cut2_hits', 'KSUBEAT CUT1', 'KSUBEAT CUT2'):
    if need not in sc2:
        raise SystemExit("!! 自检失败：%s 不在产物源码里" % need)

# ---------- C) selinux.c：本发核心，is_ksu_domain() 短路慢路 ----------
sel = load(LOCAL_SEL, SEL_MD5)

SEL_FN_ANCHOR = ("bool is_ksu_domain(void)\n"
                 "{\n"
                 "    return is_task_ksu_domain(current_cred());\n"
                 "}")
SEL_FN_NEW = """/* ===== EXP6e(§6.603)：B 截首要嫌疑正面打击 —— 慢路短路 =====
 * 本机策略里没有 u:r:ksu:s0 ⇒ cache_sid() 报 -22 ⇒ cached_su_sid 恒为 0
 * ⇒ 每次 uid==0 的 execve 判据都走慢路（secid_to_secctx 分配串 + strncmp + release），
 *   死前实测约 738 次 / 19.5 s ≈ 38 次/s。
 * ksu_exp6_noslow=1 时在入口短路：cached_su_sid==0 就直接 false。
 * ★决策不变：慢路拿当前任务 secctx 比 "u:r:ksu:s0"，本机无此域 ⇒ 必不等 ⇒ false；短路同值。
 *   只减工作量。noslow 自己带只打 3 次的计数器，保证"确实短路了"是正面证据。
 * ★不动 is_sid_match 本体 ⇒ is_zygote()/is_init() 一字不改（严格单变量）。
 */
unsigned ksu_exp6_noslow = 0;
module_param(ksu_exp6_noslow, uint, 0644);
unsigned ksu_exp6_noslow_hits = 0;

bool is_ksu_domain(void)
{
    if (unlikely(ksu_exp6_noslow && cached_su_sid == 0)) {
        ksu_exp6_noslow_hits++;
        if (ksu_exp6_noslow_hits == 1 || ksu_exp6_noslow_hits == 100 ||
            ksu_exp6_noslow_hits == 1000)
            pr_info("KSUBEAT NOSLOW hit=%u pid=%d uid=%u\\n", ksu_exp6_noslow_hits,
                    current->pid, current_uid().val);
        return false;
    }
    return is_task_ksu_domain(current_cred());
}"""
if sel.count(SEL_FN_ANCHOR) != 1:
    raise SystemExit("!! [sel] is_ksu_domain 锚点缺失或非唯一(count=%d)" % sel.count(SEL_FN_ANCHOR))
if sel.count("static u32 cached_su_sid __read_mostly = 0;") != 1:
    raise SystemExit("!! [sel] cached_su_sid 声明缺失或非唯一")
if "#include <linux/moduleparam.h>" not in sel:
    raise SystemExit("!! [sel] moduleparam.h 未包含，拒绝打补丁（module_param 无法展开）")
sel2 = sel.replace(SEL_FN_ANCHOR, SEL_FN_NEW, 1)
for need in ('ksu_exp6_noslow_hits', 'KSUBEAT NOSLOW', 'module_param(ksu_exp6_noslow,'):
    if need not in sel2:
        raise SystemExit("!! [sel] 自检失败：%s 不在产物源码里" % need)
if 'is_sid_match(cred, cached_zygote_sid' not in sel2 or 'is_sid_match(cred, cached_init_sid' not in sel2:
    raise SystemExit("!! [sel] is_zygote/is_init 被误伤，中止")

seb_b = seb2.encode()
sc_b = sc2.encode()
sel_b = sel2.encode()
print("\n==> A %d -> %d B  md5=%s" % (len(seb.encode()), len(seb_b), md5b(seb_b)))
print("==> B %d -> %d B  md5=%s" % (len(sc.encode()), len(sc_b), md5b(sc_b)))
print("==> C %d -> %d B  md5=%s" % (len(sel.encode()), len(sel_b), md5b(sel_b)))

diff("seb", seb, seb2)
diff("sucompat", sc, sc2)
diff("selinux", sel, sel2)

if not APPLY:
    print("\n==> 预览模式：未碰远端。确认 diff 后可加 --apply。")
    sys.exit(0)

print("\n==> ping:", bool(api.ping()))
for path, bk, want, name in ((SEB, BK_SEB, SEB_MD5, "seb"), (SC, BK_SC, SC_MD5, "sucompat"),
                             (SEL, BK_SEL, SEL_MD5, "selinux")):
    cur = api.exec("md5sum %s" % path, timeout=120)
    got = cur.stdout.split()[0] if cur.stdout.split() else ""
    print("==> 远端 %s 现状 md5 = %s" % (name, got))
    if got != want:
        raise SystemExit("!! 远端 %s 基线不符（期望 %s），拒绝改动。" % (name, want))
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
    got = up.stdout.split()[0] if up.stdout.split() else ""
    print("==> 上传 %s md5=%s %s" % (path, got, "OK" if got == md5b(data) else "!!!MISMATCH"))
    return got == md5b(data)


ok = False
r1 = r2 = r3 = False
try:
    if not upload(SEB, seb_b):
        raise SystemExit("!! A 上传不符，中止（将还原）")
    if not upload(SC, sc_b):
        raise SystemExit("!! B 上传不符，中止（将还原）")
    if not upload(SEL, sel_b):
        raise SystemExit("!! C 上传不符，中止（将还原）")

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
    data = api.read_bytes("kernelsu_exp6e.ko")
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
    r3 = restore_one(SEL, BK_SEL, SEL_MD5, "selinux")
    rb = api.exec("cp -f %s %s && md5sum %s" % (KO_RC80_BK, KO_REMOTE, KO_REMOTE), timeout=180)
    print("==> 远端 kernelsu.ko 还原:", rb.stdout.strip())

print("\n==> 结果:", "EXP6E_KO_OK" if (ok and r1 and r2 and r3) else "FAILED_SEE_ABOVE")
