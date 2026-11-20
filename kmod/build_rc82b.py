#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""build_rc82b.py —— A′：给 rc82_kp 加「不依赖 printk 的见证节点」，产出 rc82b。

   背景（详见 kmod/w103_evidence/RC82KP_RESULT.md §3.1 / §6）：
     rc82_kp 第 1 发在 ksu_killscan_run() 开头的 report 序列中途被硬复位，
     KILLSCAN/KSUFDINST/KSUKEEP 全靠 printk ⇒ 本机限流重 + 硬复位抹日志，读数不可靠。
     二进制对照又证明 report/killscan 段在 rc80 与 rc82_kp 里等价 ⇒
     **不需要全量重编**（那反而把 11-13 工作树 19 个 M 文件全编进来，离基线更远）。

   本脚本相对 rc82_kp 只多一个变量：
     · 在 dev_syms.c 加 /proc/ksu_kp_stat，输出 param/started/hits/now_enforcing
     · 创建点挂 ksu_dev_syms_init()(core/init.c:128，整个 init 第一件事)，
       比 report 序列早 ~0.9s ⇒ 窗口再死在 report 里也能 cat 到 started=0
     · ksu_kp_start() 里加一行 ksu_kp_started=1（唯一对看门狗逻辑的改动）
   其余逐字保持 rc82_kp 形状：两个裸接口、200ms 看门狗、ksu_kp_start() 挂
   ksu_fd_install_run() 开头、不碰 init.c、不做 clean、照抄同一条 make 命令。

   5.4.281 的 /proc API 用 struct file_operations + proc_create（struct proc_ops 是 5.6+）；
   dev_syms.c 已 include linux/proc_fs.h / linux/fs.h / linux/kernel.h / workqueue，
   零新增头文件依赖。项目硬纪律「活窗口不 rmmod、关窗靠 reboot」⇒ 不注册
   proc_remove / cancel_delayed_work_sync，避免为清理逻辑再改 kernelsu_exit()。

用法：
   python3 build_rc82b.py            # 预览：只校验锚点、写 preview 文件，不上传不编译
   python3 build_rc82b.py --apply    # 打补丁 + 编译 + 拉回 + 无条件还原源码
"""
import sys, hashlib, base64, posixpath
sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import from_config

api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")

SEL = "/root/k/ksu/kernel/selinux/selinux.c"
DEV = "/root/k/ksu/kernel/infra/dev_syms.c"
MDIR = "/root/k/ksu/kernel"
KDIR = "/root/k/nothing_sm7325_v_mr"
LOG = "/home/lucy/rc82b_build.log"
KO_REMOTE = "/root/k/ksu/kernel/kernelsu.ko"
KO_HOME = "/home/lucy/kernelsu_rc82b.ko"
LOCAL_KO = r"G:/项目/Windows管理/usb/临时root/kmod/kernelsu_rc82b.ko"
APPLY = "--apply" in sys.argv

# ── selinux.c：两个裸接口（与 rc82_kp 逐字相同）────────────────────────────
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

# ── dev_syms.c：整块插在 bool ksu_mass_mark = true; 之前 ───────────────────
# 必须放在 439 行 ksu_dev_syms_init() 之前，否则它引用 fops 会「未声明」。
DEV_BLOCK_ANCHOR = "bool ksu_mass_mark = true;\n"
DEV_BLOCK_INSERT = """/* ★★rc82b keep-permissive 看门狗（默认关）+ /proc 见证节点。
 *   事故(11-13 16:3x)：模块 apply 成功但 SELinux 被设回 Enforcing ⇒ su 通道两腿全断，
 *   而 /sys/fs/selinux/enforce 是 0644 root ⇒ 没 root 翻不回去，只能 reboot。
 *   ⇒ 内核侧兜住：发现 enforcing==1 就写回 0，不改策略，只改这一个布尔。默认关。
 *   ★rc82b 新增见证：KSUKEEP/KSUFDINST 都靠 printk，本机限流重且硬复位会抹日志
 *     ⇒ /proc/ksu_kp_stat 直接给读数，且**创建点早于 killscan 的 report 序列**。 */
extern bool ksu_enforce_get_raw(void);
extern void ksu_enforce_force_permissive(void);

static unsigned int ksu_keep_permissive = 0;
module_param(ksu_keep_permissive, uint, 0644);
MODULE_PARM_DESC(ksu_keep_permissive, "1=每 200ms 把 SELinux 拉回 Permissive(默认 0=不动)");

static struct delayed_work ksu_kp_work;
static unsigned long ksu_kp_hits;
static unsigned int ksu_kp_started;
static struct proc_dir_entry *ksu_kp_stat_pe;

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
    ksu_kp_started = 1;   /* ★rc82b 唯一新增的一行：见证「活到了 ksu_fd_install_run()」 */
    pr_info("KSUKEEP 已启动(200ms 节拍) hits=%lu\\n", ksu_kp_hits);
}

/* ★rc82b 见证节点：5.4 用 struct file_operations + proc_create（proc_ops 是 5.6+）。
 * 用 snprintf + simple_read_from_buffer，避免为它新加 seq_file 依赖。
 * 模式 0400：读数含 SELinux 状态与 hits，不给 app/shell 全开。 */
static ssize_t ksu_kp_stat_read(struct file *f, char __user *ubuf,
                                size_t n, loff_t *pos)
{
    char buf[192];
    int len = scnprintf(buf, sizeof(buf),
        "param=%u started=%u hits=%lu now_enforcing=%d\\n",
        ksu_keep_permissive, ksu_kp_started, ksu_kp_hits,
        ksu_enforce_get_raw() ? 1 : 0);
    return simple_read_from_buffer(ubuf, n, pos, buf, len);
}

static const struct file_operations ksu_kp_stat_fops = {
    .owner = THIS_MODULE,
    .read  = ksu_kp_stat_read,
};

"""

# ── dev_syms.c：在 ksu_dev_syms_init() 函数体第一行后建节点 ────────────────
DEV_INIT_ANCHOR = "int ksu_dev_syms_init(void)\n{\n"
DEV_INIT_CALL = ("\t/* ★rc82b：见证节点尽早建好(core/init.c:128，整个 init 第一件事)，\n"
                 "\t * 比 killscan 的 report 序列早 ~0.9s ⇒ 死在 report 里也能读到 started=0。 */\n"
                 "\tif (!ksu_kp_stat_pe)\n"
                 "\t\tksu_kp_stat_pe = proc_create(\"ksu_kp_stat\", 0400, NULL, &ksu_kp_stat_fops);\n")

# ── dev_syms.c：ksu_fd_install_run() 开头启动看门狗（与 rc82_kp 相同）──────
DEV_START_ANCHOR = "void ksu_fd_install_run(void)\n{\n"
DEV_START_CALL = "    ksu_kp_start();\n"


def md5b(b):
    return hashlib.md5(b).hexdigest()


def exec_upload(target, raw):
    b64 = base64.b64encode(raw).decode()
    chunks = [b64[i:i + 900] for i in range(0, len(b64), 900)] or [""]
    cmds = ["mkdir -p %s" % posixpath.dirname(target), ": > %s.b64" % target]
    for c in chunks:
        cmds.append("printf %%s %s >> %s.b64" % (c, target))
    cmds += ["base64 -d %s.b64 > %s" % (target, target), "rm -f %s.b64" % target,
             "md5sum %s" % target]
    res = api.exec("\n".join(cmds), timeout=240)
    got = res.stdout.split()[0] if res.stdout.split() else ""
    if res.exit_code != 0 or got != md5b(raw):
        raise RuntimeError("upload %s 失败 rc=%s got=%s" % (target, res.exit_code, got))
    return got


def check_anchor(txt, anchor, name):
    n = txt.count(anchor)
    if n != 1:
        raise RuntimeError("%s 锚点出现 %d 次(要求 1) ⇒ 停" % (name, n))
    print("==> 锚点 %-22s : 1 次 ✓" % name, flush=True)


print("==> ping:", "ok" if api.ping() else "FAIL", flush=True)

# ── 读源码 + 校验全部 4 个锚点（只读）──────────────────────────────────────
sel_txt = api.exec("cat %s" % SEL, timeout=120).stdout
dev_txt = api.exec("cat %s" % DEV, timeout=120).stdout
print("==> 读到 selinux.c %d 字符 / dev_syms.c %d 字符（中文注释多，字符数 < 字节数属正常）"
      % (len(sel_txt), len(dev_txt)), flush=True)
# exec() 的 stdout 走 decode(errors="replace")；中文注释若被截断会变成 U+FFFD，
# 写回去就成了坏源码（而 md5 自校验发现不了，因为比的是同一份坏内容）。
for nm, t in (("selinux.c", sel_txt), ("dev_syms.c", dev_txt)):
    if "\ufffd" in t:
        raise RuntimeError("%s 读回含 U+FFFD 替换字符 ⇒ exec/cat 通道损坏，停" % nm)
print("==> U+FFFD 自检：干净 ✓", flush=True)

check_anchor(sel_txt, SEL_ANCHOR, "SEL getenforce")
check_anchor(dev_txt, DEV_BLOCK_ANCHOR, "DEV mass_mark")
check_anchor(dev_txt, DEV_INIT_ANCHOR, "DEV dev_syms_init")
check_anchor(dev_txt, DEV_START_ANCHOR, "DEV fd_install_run")
for bad in ("ksu_keep_permissive", "ksu_kp_stat_pe", "ksu_enforce_get_raw"):
    if bad in dev_txt or bad in sel_txt:
        raise RuntimeError("源码里已有 %s ⇒ 上次的补丁没还原干净，停" % bad)
print("==> rc82 残留检查：干净 ✓", flush=True)

# ── 组装补丁 ──────────────────────────────────────────────────────────────
sel_new = sel_txt.replace(SEL_ANCHOR, SEL_INSERT + SEL_ANCHOR, 1)
dev_new = dev_txt.replace(DEV_BLOCK_ANCHOR, DEV_BLOCK_INSERT + DEV_BLOCK_ANCHOR, 1)
dev_new = dev_new.replace(DEV_INIT_ANCHOR, DEV_INIT_ANCHOR + DEV_INIT_CALL, 1)
dev_new = dev_new.replace(DEV_START_ANCHOR, DEV_START_ANCHOR + DEV_START_CALL, 1)
print("==> selinux.c %d -> %d (+%d)" % (len(sel_txt), len(sel_new), len(sel_new) - len(sel_txt)), flush=True)
print("==> dev_syms.c %d -> %d (+%d)" % (len(dev_txt), len(dev_new), len(dev_new) - len(dev_txt)), flush=True)

if not APPLY:
    open(r"G:/项目/Windows管理/usb/临时root/kmod/rc82b_selinux_preview.c", "w", encoding="utf-8").write(sel_new)
    open(r"G:/项目/Windows管理/usb/临时root/kmod/rc82b_dev_syms_preview.c", "w", encoding="utf-8").write(dev_new)
    print("==> 预览模式：已写 2 个 preview，未上传/未编译/未改远端", flush=True)
    sys.exit(0)

# ── 备份 → 上传 → 编译 → 拉回 → 还原 ──────────────────────────────────────
for p in (SEL, DEV):
    b = api.exec("cp -f %s %s.rc82bbak && md5sum %s.rc82bbak" % (p, p, p), timeout=120)
    print("==> 备份 %s : %s" % (p.split('/')[-1], b.stdout.strip()[:60]), flush=True)

# 记录 sucompat.o 的 mtime，编译后核对它没被重编（A′ 的关键约束）
o_before = api.exec("stat -c %%Y %s/feature/sucompat.o" % MDIR, timeout=60).stdout.strip()
print("==> sucompat.o mtime(before) =", o_before, flush=True)

exec_upload(SEL, sel_new.encode())
exec_upload(DEV, dev_new.encode())
print("==> 两件已写入远端", flush=True)

# 与 build_rc82_kp.py **逐字相同**的 make 命令 ⇒ if_changed 不触发无关重编
make = ("cd %s && make -C %s M=%s src=%s CONFIG_KSU=m ARCH=arm64 "
        "CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld AR=llvm-ar "
        "NM=llvm-nm OBJCOPY=llvm-objcopy STRIP=llvm-strip "
        'KCFLAGS="-include /home/lucy/ksu_compat54.h" '
        "modules -j32 > %s 2>&1; echo EXITCODE=$?") % (KDIR, KDIR, MDIR, MDIR, LOG)
print("==> 编译中 ...", flush=True)
br = api.exec(make, timeout=900)
print("==> build rc:", br.exit_code, br.stdout.strip()[-40:], flush=True)
log = api.exec("tail -40 %s" % LOG, timeout=120).stdout
print(log[-2500:], flush=True)

# 编译了哪些 .o（A′ 期望只有 selinux.o / dev_syms.o + 链接产物）
compiled = api.exec("grep -E '^\\s*(CC|LD)\\[M\\]' %s | tail -20" % LOG, timeout=120).stdout
print("==> 本轮 CC/LD 清单:\n%s" % compiled[-2000:], flush=True)
o_after = api.exec("stat -c %%Y %s/feature/sucompat.o" % MDIR, timeout=60).stdout.strip()
print("==> sucompat.o mtime(after)  =", o_after,
      "⇒", "未重编 ✓" if o_after == o_before else "★被重编了（需复核）", flush=True)

cpk = api.exec("cp -f %s %s && ls -l %s" % (KO_REMOTE, KO_HOME, KO_HOME), timeout=120)
print("==> ko:", cpk.stdout.strip(), flush=True)
data = api.read_bytes("kernelsu_rc82b.ko")
print("==> 拉回 %d 字节 md5=%s" % (len(data), md5b(data)), flush=True)
if len(data) > 100000:
    open(LOCAL_KO, "wb").write(data)
    print("==> 已写:", LOCAL_KO, flush=True)

# 无条件还原源码
for p in (SEL, DEV):
    r = api.exec("cp -f %s.rc82bbak %s && md5sum %s" % (p, p, p), timeout=120)
    print("==> 还原 %s : %s" % (p.split('/')[-1], r.stdout.strip()[:50]), flush=True)
