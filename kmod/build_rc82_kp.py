#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""build_rc82_kp.py —— rc82：给 ko 加一个"保持 Permissive"的看门狗（默认关）。
   为什么：模块 apply（如 RCQ 的"加载全部模块"）会把 SELinux 设回 Enforcing，而我们的 su 通道
   两条腿（bound su 的 shell_data_file 标签、@suwshd socket）在执法态下全被拒（实测 errno=13）。
   做法：selinux.c 导出两个**绕过 ksu_stage 门控**的裸接口；dev_syms.c 加 200ms 延时工作队列，
        发现 enforcing==1 就写回 0；参数 `ksu_keep_permissive` 默认 0（交付形状一字不变）。
   前置事实（读源码得到，不是猜的）：
     · selinux.c 里已有 `void setenforce(bool)`（写 ksu_p_selinux_state->enforcing，但被 ksu_stage_ok(9) 门控）
       与 `bool getenforce(void)`；init.c:182 原本是 `if(!getenforce()) setenforce(true);`（KSU 自己会恢复执法）。
     · infra/dev_syms.c 已有 work_struct 用法（ksu_guard_work），且 `ksu_fd_install_run()` 在
       core/init.c:205 被**无条件**调用 ⇒ 把启动点挂在这里最稳。
用法：python3 build_rc82_kp.py [--apply]
"""
import sys, hashlib, base64, posixpath
sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import from_config

api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")
SEL = "/root/k/ksu/kernel/selinux/selinux.c"
DEV = "/root/k/ksu/kernel/infra/dev_syms.c"
MDIR = "/root/k/ksu/kernel"
KDIR = "/root/k/nothing_sm7325_v_mr"
LOG = "/home/lucy/rc82_build.log"
KO_REMOTE = "/root/k/ksu/kernel/kernelsu.ko"
KO_HOME = "/home/lucy/kernelsu_rc82_kp.ko"
LOCAL_KO = r"G:/项目/Windows管理/usb/临时root/kmod/kernelsu_rc82_kp.ko"
APPLY = "--apply" in sys.argv

# ---- selinux.c：在 bool getenforce(void) 之前插两个裸接口 ----
SEL_ANCHOR = "bool getenforce(void)\n{\n"
SEL_INSERT = """/* ★rc82: 给"保持 Permissive"看门狗用的**裸接口** —— 刻意绕过 ksu_stage 门控，
 *   因为它要写的正是"模块 apply 之后那一下 enforce=1"，而 setenforce() 在 ksu_stage<9 时直接 return。
 *   只动 ksu_p_selinux_state->enforcing 这一个布尔，不碰策略、不碰 LSM 钩子。 */
bool ksu_enforce_get_raw(void)
{
#ifdef CONFIG_SECURITY_SELINUX_DEVELOP
    if (!ksu_p_selinux_state)
        return true;
    return ksu_p_selinux_state->enforcing;
#else
    return true;
#endif
}

void ksu_enforce_force_permissive(void)
{
#ifdef CONFIG_SECURITY_SELINUX_DEVELOP
    if (ksu_p_selinux_state)
        ksu_p_selinux_state->enforcing = false;
#endif
}

"""

# ---- dev_syms.c：在 ksu_fd_install_run 之前插整块；在函数开头插启动调用 ----
DEV_ANCHOR = "void ksu_fd_install_run(void)\n{\n"
DEV_INSERT = """/* ★★rc82 keep-permissive 看门狗（默认关）：
 *   一手事故（2026-11-13 16:3x）：用户在管理器里点「RCQ环境 → 加载全部模块」，模块 apply 成功
 *   （zn-daemon/lspd 起来了），但 SELinux 被设回 Enforcing ⇒ 我们的 su 通道**两条腿同时断**：
 *     /product/bin/su 的标签是 shell_data_file（执法态 app 域 exec 被拒）；
 *     @suwshd 的 abstract socket connect 也被拒（errno=13）。
 *   而 /sys/fs/selinux/enforce 是 0644 root ⇒ 没 root 就翻不回去（死锁，只能 reboot）。
 *   ⇒ 由内核侧兜住：发现 enforcing==1 就写回 0。**不改策略**，只改这一个布尔。
 *   ★风险已知：与模块脚本的 setenforce 形成 200ms 拉锯；所以默认关，只在实验窗口里开。 */
extern bool ksu_enforce_get_raw(void);
extern void ksu_enforce_force_permissive(void);

static unsigned ksu_keep_permissive = 0;
module_param(ksu_keep_permissive, uint, 0644);
MODULE_PARM_DESC(ksu_keep_permissive, "1=每 200ms 把 SELinux 拉回 Permissive(默认 0=不动)");

static struct delayed_work ksu_kp_work;
static unsigned long ksu_kp_hits;

static void ksu_kp_fn(struct work_struct *w)
{
    if (!ksu_keep_permissive)
        return;
    if (ksu_enforce_get_raw()) {
        ksu_enforce_force_permissive();
        ksu_kp_hits++;
        if ((ksu_kp_hits & 0x1F) == 1)
            pr_info("KSUKEEP enforce 1->0 第 %lu 次\\n", ksu_kp_hits);
    }
    schedule_delayed_work(&ksu_kp_work, msecs_to_jiffies(200));
}

static void ksu_kp_start(void)
{
    if (!ksu_keep_permissive) {
        pr_info("KSUKEEP 未开(默认) ⇒ 不动 MAC\\n");
        return;
    }
    INIT_DELAYED_WORK(&ksu_kp_work, ksu_kp_fn);
    schedule_delayed_work(&ksu_kp_work, msecs_to_jiffies(200));
    pr_info("KSUKEEP 已启动(200ms 节拍) hits=%lu\\n", ksu_kp_hits);
}

"""


def md5b(b):
    return hashlib.md5(b).hexdigest()


def exec_upload(target, raw):
    b64 = base64.b64encode(raw).decode()
    chunks = [b64[i:i + 900] for i in range(0, len(b64), 900)] or [""]
    cmds = ["mkdir -p %s" % posixpath.dirname(target), ": > %s.b64" % target]
    for c in chunks:
        cmds.append("printf %%s %s >> %s.b64" % (c, target))
    cmds += ["base64 -d %s.b64 > %s" % (target, target), "rm -f %s.b64" % target, "md5sum %s" % target]
    res = api.exec("\n".join(cmds), timeout=240)
    got = res.stdout.split()[0] if res.stdout.split() else ""
    if res.exit_code != 0 or got != md5b(raw):
        raise RuntimeError("upload %s 失败 rc=%s got=%s" % (target, res.exit_code, got))
    return got


def patch(path, anchor, insert, count_required=1):
    txt = api.exec("cat %s" % path, timeout=120).stdout
    n = txt.count(anchor)
    if n != count_required:
        raise RuntimeError("%s 锚点出现 %d 次(要求 %d) ⇒ 停" % (path, n, count_required))
    return txt, txt.replace(anchor, insert + anchor, 1)


print("==> ping:", "ok" if api.ping() else "FAIL")

# 备份
for p in (SEL, DEV):
    b = api.exec("cp -f %s %s.rc82bak && md5sum %s.rc82bak" % (p, p, p), timeout=120)
    print("==> 备份 %s : %s" % (p.split('/')[-1], b.stdout.strip()[:60]))

# 打补丁（先算好两处文本）
sel_txt, sel_new = patch(SEL, SEL_ANCHOR, SEL_INSERT)
dev_txt, dev_new = patch(DEV, DEV_ANCHOR, DEV_INSERT)
# 第二处：在函数体第一行插入启动调用
dev_new = dev_new.replace(DEV_ANCHOR, DEV_ANCHOR + "    ksu_kp_start();\n", 1)
print("==> selinux.c %d -> %d (+%d)" % (len(sel_txt), len(sel_new), len(sel_new) - len(sel_txt)))
print("==> dev_syms.c %d -> %d (+%d)" % (len(dev_txt), len(dev_new), len(dev_new) - len(dev_txt)))

if not APPLY:
    open(r"G:/项目/Windows管理/usb/临时root/kmod/rc82_selinux_preview.c", "w", encoding="utf-8").write(sel_new)
    open(r"G:/项目/Windows管理/usb/临时root/kmod/rc82_dev_syms_preview.c", "w", encoding="utf-8").write(dev_new)
    print("==> 预览模式：已写两个 preview 文件，未上传、未编译")
    sys.exit(0)

exec_upload(SEL, sel_new.encode())
exec_upload(DEV, dev_new.encode())
print("==> 两件已写入远端")

make = ("cd %s && make -C %s M=%s src=%s CONFIG_KSU=m ARCH=arm64 "
        "CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld AR=llvm-ar "
        "NM=llvm-nm OBJCOPY=llvm-objcopy STRIP=llvm-strip "
        'KCFLAGS="-include /home/lucy/ksu_compat54.h" '
        "modules -j32 > %s 2>&1; echo EXITCODE=$?") % (KDIR, KDIR, MDIR, MDIR, LOG)
print("==> 编译中 ...")
br = api.exec(make, timeout=900)
print("==> build rc:", br.exit_code, br.stdout.strip()[-30:])
log = api.exec("tail -40 %s" % LOG, timeout=120).stdout   # 用 exec 读，避开 FileBrowser 监狱
print(log[-2500:])

cpk = api.exec("cp -f %s %s && ls -l %s" % (KO_REMOTE, KO_HOME, KO_HOME), timeout=120)
print("==> ko:", cpk.stdout.strip())
data = api.read_bytes("kernelsu_rc82_kp.ko")
print("==> 拉回 %d 字节 md5=%s" % (len(data), md5b(data)))
if len(data) > 100000:
    open(LOCAL_KO, "wb").write(data)
    print("==> 已写:", LOCAL_KO)

# 无条件还原源码
for p in (SEL, DEV):
    r = api.exec("cp -f %s.rc82bak %s && md5sum %s" % (p, p, p), timeout=120)
    print("==> 还原 %s : %s" % (p.split('/')[-1], r.stdout.strip()[:50]))
