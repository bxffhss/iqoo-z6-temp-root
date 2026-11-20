#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Exp-6b 构建（§6.599 续）：在 Exp-6 的 mode 分档之上，再加一个 sucompat 热路径打印总闸。

要判的问题（§6.599 已把死因收敛到 sucompat 支，剩两条候选）：
  (i) 每次 execve 一条 `pr_info("KSUBEAT SD1 …")`（实测 822 条 / 20.5 s ≈ 40 条/s，
      末行即 SD1）同步走 console + console_lock 串行 ⇒ 拖成 watchdog ⇒ PMIC 硬复位；
  (ii) sucompat 的逻辑本身，或"进真 execve 前多背 5–6 层帧"的栈深度。

`ksu_exp6_quiet=1` **只静音、不改逻辑、不减任何调用帧** ⇒ 天然判别器：
  活 ⇒ (i) 成立；崩 ⇒ (i) 排除，只剩 (ii)。

改动（两个文件，各自 md5 硬闸 + 无条件还原）：
  A) hook/syscall_event_bridge.c（基线 26dd9a0af093d31d04ec73484a530fee）：
     与 Exp-6 完全相同的 3 处守卫 + ksu_exp6_mode 参数块（保持同谱系可比）。
  B) feature/sucompat.c（基线 0a305171e7b5b1bb338862ee9639e974）：
     + ksu_exp6_quiet 参数 + ksu_hp_pr() 宏；把全部 17 处 `pr_info/pr_warn("KSUBEAT S…")`
       换成 ksu_hp_pr(...)（SD0..SD5 / SU0..SU4）。**不动那 63 行重复的 path[0]=0;**
       ——本轮要单变量，清垃圾留到下一发，免得同一个 boot 混两个改动。

用法：python build_exp6b.py            # 预览
     python build_exp6b.py --apply    # 备份+上传+编译+拉回+无条件还原
"""
import sys, hashlib, base64, difflib

sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import from_config

SEB = "/root/k/ksu/kernel/hook/syscall_event_bridge.c"
SC = "/root/k/ksu/kernel/feature/sucompat.c"
BK_SEB = "/tmp/seb_exp6b_orig.c"
BK_SC = "/tmp/sucompat_exp6b_orig.c"
MDIR = "/root/k/ksu/kernel"
KDIR = "/root/k/nothing_sm7325_v_mr"
LOG = "/home/lucy/exp6b_build.log"
KO_REMOTE = "/root/k/ksu/kernel/kernelsu.ko"
KO_RC80_BK = "/home/lucy/kernelsu_rc80_backup.ko"
KO_HOME = "/home/lucy/kernelsu_exp6b.ko"
LOCAL_SEB = r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/seb_remote_now.c"
LOCAL_SC = r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/sucompat_remote_now.c"
LOCAL_KO = r"G:/项目/Windows管理/usb/临时root/kmod/kernelsu_exp6b.ko"
RC80_KO = r"G:/项目/Windows管理/usb/临时root/kmod/kernelsu_rc80.ko"
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
                                     lineterm="", n=2):
        print(line)
    ch = [l for l in difflib.unified_diff(a.splitlines(), b.splitlines(), lineterm="", n=0)
          if l.startswith(("+", "-")) and not l.startswith(("+++", "---"))]
    print("==> %s 改动行数 = %d" % (label, len(ch)))
    return len(ch)


# ---------- A) syscall_event_bridge.c：与 Exp-6 同一套 mode 守卫 ----------
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
 *                4=三支全摘(≈Exp-5' noop，本谱系自洽对照)
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

# ---------- B) sucompat.c：quiet 总闸 ----------
sc = load(LOCAL_SC, SC_MD5)

SC_ANCHOR = "bool ksu_su_compat_enabled __read_mostly = true;"
SC_BLOCK = """

/* ===== EXP6b(§6.599)：sucompat 热路径打印总闸 =====
 * ksu_exp6_quiet=1 ⇒ 把全部 KSUBEAT S… 热路径打印静音（SD0..SD5 / SU0..SU4，共 17 处）。
 * ★只静音：逻辑一行不改、往真 execve 里的调用帧一层不减 ⇒ 它是「打印/console 串行」与
 *   「逻辑/栈深度」这两条候选的判别器（§6.599）。
 */
unsigned ksu_exp6_quiet = 0;
module_param(ksu_exp6_quiet, uint, 0644);
#define ksu_hp_pr(fmt, ...) do { if (unlikely(!ksu_exp6_quiet)) pr_info(fmt, ##__VA_ARGS__); } while (0)
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

seb_b = seb2.encode()
sc_b = sc2.encode()
print("\n==> A %d -> %d B  md5=%s" % (len(seb.encode()), len(seb_b), md5b(seb_b)))
print("==> B %d -> %d B  md5=%s" % (len(sc.encode()), len(sc_b), md5b(sc_b)))

diff("seb", seb, seb2)
diff("sucompat", sc, sc2)

if not APPLY:
    print("\n==> 预览模式：未碰远端。确认 diff 后可加 --apply。")
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
        for ln in api.read(LOG).splitlines()[-20:]:
            print("   ", ln)
        raise SystemExit("!! 编译未成功")

    cp = api.exec("cp -f %s %s && ls -l %s && md5sum %s" % (KO_REMOTE, KO_HOME, KO_HOME, KO_HOME),
                  timeout=180)
    print("==> ko cp:", cp.stdout.strip())
    data = api.read_bytes("kernelsu_exp6b.ko")
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

print("\n==> 结果:", "EXP6B_KO_OK" if (ok and r1 and r2) else "FAILED_SEE_ABOVE")
