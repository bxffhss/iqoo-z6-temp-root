#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rc59：给 sucompat 的"探测伪装"两个 handler 装**分步回执** + 一个**能把本体关掉的 A/B 开关**（md §6.119③）。

背景（一手，两条假设已被否）：
  · 开 `ksu_hook_mask` 的位 4(faccessat) 或位 3+4 ⇒ 授权 uid 的 app 一起来就整机复位(§6.116/§6.118)；
  · 不是 CFI 桩：`CFIFIX __arm64_sys_newfstatat/faccessat … B->本体 ✓ 不用改`(§6.119①)；
  · 不是 printk 洪印：rc58 把入口回执按号收紧+限流之后**照样死**(§6.119①)。
⇒ 不再猜第三次。这一版只做两件事：
  ① 在两个 handler 里按步骤印 `FA0..FA6`/`FS0..FS6`（`pr_info_ratelimited`，且只在"这个 uid 有资格"时印，
     所以不会把 syscall 入口刷死），死在哪一行下一发的 dmesg 直接说；
  ② 加 insmod 参数 `ksu_stat_off`：**钩子照挂、handler 直接回落原实现**
     ⇒ 一发就能把死因劈成"挂在 48/79 上这件事本身致命" vs "handler 里某一行致命"。
用法：python3 patch_ksu_statprobe_steps.py <KSU 源码根>     # 幂等
"""
import io
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"
SC = M + "/feature/sucompat.c"

PARAM = """/* rc59(md §6.119③)：A/B 开关。=1 时**钩子照挂**，但两个"探测伪装"handler 什么都不做，
 * 直接回落原实现 ⇒ 一发就能把死因劈成"挂在 faccessat/newfstatat 上本身致命"与"handler 内部致命"。 */
bool ksu_stat_off __read_mostly = false;
module_param(ksu_stat_off, bool, 0444);
MODULE_PARM_DESC(ksu_stat_off, "sucompat: 挂着 stat/faccessat 钩子但不做探测伪装(直接回落原实现)");

"""

# ---------------- faccessat ----------------
A_OLD = """long ksu_handle_faccessat_sucompat(int orig_nr, struct pt_regs *regs)
{
    const char __user **filename_user, *orig_filename;
    long ret;
    const struct cred *old_cred;

    if (!ksu_is_allow_uid_for_current(current_uid().val)) {
        goto do_orig_facessat;
    }
"""
A_NEW = """long ksu_handle_faccessat_sucompat(int orig_nr, struct pt_regs *regs)
{
    const char __user **filename_user, *orig_filename;
    long ret;
    const struct cred *old_cred;

    if (ksu_stat_off) {
        static atomic_t off_cnt = ATOMIC_INIT(0);
        if (atomic_inc_return(&off_cnt) <= 4)
            pr_info("KSUBEAT FAoff faccessat 钩子在跑但本体被 ksu_stat_off=1 关掉 n=%d uid=%u\\n",
                    atomic_read(&off_cnt), current_uid().val);
        goto do_orig_facessat;
    }
    if (!ksu_is_allow_uid_for_current(current_uid().val)) {
        goto do_orig_facessat;
    }
    pr_info_ratelimited("KSUBEAT FA0 enter faccessat: uid=%u pid=%d comm=%s\\n",
                        current_uid().val, current->pid, current->comm);
"""

B_OLD = """    char path[sizeof(su_path) + 1];
    memset(path, 0, sizeof(path));
    strncpy_from_user_nofault(path, *filename_user, sizeof(path));

    if (unlikely(!memcmp(path, su_path, sizeof(su_path)))) {
        old_cred = override_creds(ksu_cred);
        if (is_ksud_exists()) {
            pr_info("faccessat su->ksud!\\n");
            orig_filename = *filename_user;
            *filename_user = ksud_user_path();
            ret = ksu_syscall_table[orig_nr](regs);
            revert_creds(old_cred);
            *filename_user = orig_filename;
            return ret;
        } else {
            revert_creds(old_cred);
        }
    }
"""
B_NEW = """    char path[sizeof(su_path) + 1];
    long npath;
    memset(path, 0, sizeof(path));
    npath = strncpy_from_user_nofault(path, *filename_user, sizeof(path));
    /* ★`path` 只有 sizeof(su_path)+1=17 字节；`npath==17` 意味着源串更长、**没有 NUL 结尾**
     *   (strncpy_from_user 截断时不补 0) ⇒ 用 %s 印它会在栈上越过缓冲区读到下一个 0。
     *   上游只做定长 memcmp 所以没这问题——这是我塞回执塞出来的 bug，必须 %.16s。 */
    pr_info_ratelimited("KSUBEAT FA1 抄路径=%ld 内容=[%.16s] 指针=%px\\n", npath, path,
                        (void *)*filename_user);

    if (unlikely(!memcmp(path, su_path, sizeof(su_path)))) {
        pr_info_ratelimited("KSUBEAT FA2 命中 su 路径 ⇒ override_creds(ksu_cred=%px)\\n",
                            (void *)ksu_cred);
        old_cred = override_creds(ksu_cred);
        if (is_ksud_exists()) {
            pr_info_ratelimited("KSUBEAT FA3 ksud 在(%s) ⇒ 换指针进原实现\\n", ksu_ksud_path);
            orig_filename = *filename_user;
            *filename_user = ksud_user_path();
            ret = ksu_syscall_table[orig_nr](regs);
            pr_info_ratelimited("KSUBEAT FA4 原实现返回 ret=%ld，指针已还原\\n", ret);
            revert_creds(old_cred);
            *filename_user = orig_filename;
            return ret;
        } else {
            pr_info_ratelimited("KSUBEAT FA3e is_ksud_exists()=假(%s) ⇒ 还原 cred\\n", ksu_ksud_path);
            revert_creds(old_cred);
        }
    }
"""
C_OLD = """do_orig_facessat:
    return ksu_syscall_table[orig_nr](regs);
"""
C_NEW = """do_orig_facessat:
    /* FA5：走到这里=_decline_（没资格/路径不匹配/ksud 不在/开关关了）。
     * 若下一发的回执停在 FA5 而机器仍死 ⇒ 死因在"从钩子里调 ksu_syscall_table[48]"这一步本身。 */
    pr_info_ratelimited("KSUBEAT FA5 decline→原实现 nr=%d uid=%u\\n", orig_nr, current_uid().val);
    return ksu_syscall_table[orig_nr](regs);
"""

# ---------------- newfstatat ----------------
D_OLD = """    if (!ksu_is_allow_uid_for_current(current_uid().val)) {
        goto do_orig_stat;
    }
"""
D_NEW = """    if (ksu_stat_off)
        goto do_orig_stat;
    if (!ksu_is_allow_uid_for_current(current_uid().val)) {
        goto do_orig_stat;
    }
    pr_info_ratelimited("KSUBEAT FS0 enter newfstatat: uid=%u pid=%d comm=%s\\n",
                        current_uid().val, current->pid, current->comm);
"""
E_OLD = """do_orig_stat:
    return ksu_syscall_table[orig_nr](regs);
"""
E_NEW = """do_orig_stat:
    pr_info_ratelimited("KSUBEAT FS5 decline→原实现 nr=%d uid=%u\\n", orig_nr, current_uid().val);
    return ksu_syscall_table[orig_nr](regs);
"""


def sub(s, old, new, tag):
    if new in s:
        print("  已打过(跳过): %s" % tag)
        return s, True
    n = s.count(old)
    if n != 1:
        print("!! 锚点命中 %d 次(要正好 1) ⇒ 跳过: %s" % (n, tag))
        return s, False
    print("  ok %s" % tag)
    return s.replace(old, new, 1), True


def main():
    s = io.open(SC, encoding="utf-8").read()
    ok = True
    if "ksu_stat_off" not in s:
        anchor = "static char ksu_ksud_path[64] = KSUD_PATH;\n"
        if s.count(anchor) != 1:
            print("!! 参数锚点命中 %d 次 ⇒ 停" % s.count(anchor))
            return 1
        s = s.replace(anchor, PARAM + anchor, 1)
        print("  ok 参数 ksu_stat_off")
    for old, new, tag in ((A_OLD, A_NEW, "FA0/FAoff"), (B_OLD, B_NEW, "FA1..FA4"),
                          (C_OLD, C_NEW, "FA5"), (D_OLD, D_NEW, "FS0/stat_off"),
                          (E_OLD, E_NEW, "FS5")):
        s, r = sub(s, old, new, tag)
        ok &= r
    io.open(SC, "w", encoding="utf-8", newline="\n").write(s)
    s2 = io.open(SC, encoding="utf-8").read()
    print("  校验: " + " ".join("%s=%d" % (k, s2.count(k))
          for k in ("KSUBEAT FA0", "KSUBEAT FA1", "KSUBEAT FA5", "KSUBEAT FS0", "KSUBEAT FS5",
                    "ksu_stat_off", "atomic_t off_cnt")))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
