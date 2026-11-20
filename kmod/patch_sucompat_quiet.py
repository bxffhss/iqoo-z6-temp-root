#!/usr/bin/env python3
# patch_sucompat_quiet.py —— 把 sucompat 的 faccessat/newfstatat 两个 handler 换成"无名打印"版
#
# 为什么：rc77 里这两个函数是调试形状——
#   · ksu_handle_stat_sucompat 有 9 条重复的 `if (ksu_stat_off) goto ...`
#   · 13 条一模一样的 pr_info("KSUBEAT FS0 enter newfstatat ...")
#   · 每条未命中都打一条 FS5 decline
# 一旦把 ksu_hook_mask 的 bit3(newfstatat)/bit4(faccessat) 打开，全机热路径会变成
# "每个 stat/access 打十几行" ⇒ 环被冲垮、装载期就是死因（历史上"打印乘数"那条）。
# 本补丁只删打印/重复行，判定逻辑与 rc77 逐字等价（memcmp 命中 + override_creds + 换指针重入原 syscall）。
import sys, re

P = sys.argv[1] if len(sys.argv) > 1 else '/root/k/ksu/kernel/feature/sucompat.c'
s = open(P, encoding='utf-8', errors='surrogateescape').read()

NEW_FA = r'''long ksu_handle_faccessat_sucompat(int orig_nr, struct pt_regs *regs)
{
    const char __user **filename_user, *orig_filename;
    long ret;
    const struct cred *old_cred;
    char path[sizeof(su_path) + 1];

    /* rc78：社区路线（探测伪装），热路径零打印。逻辑与 rc77 等价，只去掉 KSUBEAT FA* 调试输出。 */
    if (ksu_stat_off)
        goto do_orig_facessat;
    if (!ksu_is_allow_uid_for_current(current_uid().val))
        goto do_orig_facessat;

    filename_user = (const char __user **)&PT_REGS_PARM2(regs);
    memset(path, 0, sizeof(path));
    if (strncpy_from_user_nofault(path, *filename_user, sizeof(path)) < 0)
        goto do_orig_facessat;

    if (unlikely(!memcmp(path, su_path, sizeof(su_path)))) {
        old_cred = override_creds(ksu_cred);
        if (is_ksud_exists()) {
            orig_filename = *filename_user;
            *filename_user = ksud_user_path();
            ret = ksu_syscall_table[orig_nr](regs);
            revert_creds(old_cred);
            *filename_user = orig_filename;
            return ret;
        }
        revert_creds(old_cred);
    }

do_orig_facessat:
    return ksu_syscall_table[orig_nr](regs);
}
'''

NEW_FS = r'''long ksu_handle_stat_sucompat(int orig_nr, struct pt_regs *regs)
{
    const char __user **filename_user, *orig_filename;
    long ret;
    const struct cred *old_cred;
    char path[sizeof(su_path) + 1];

    /* rc78：同上——去掉 rc77 里 9 条重复的 `if (ksu_stat_off)` 与 13 条 FS0 打印、以及 FS5 decline。 */
    if (ksu_stat_off)
        goto do_orig_stat;
    if (!ksu_is_allow_uid_for_current(current_uid().val))
        goto do_orig_stat;

    filename_user = (const char __user **)&PT_REGS_PARM2(regs);
    memset(path, 0, sizeof(path));
    if (strncpy_from_user_nofault(path, *filename_user, sizeof(path)) < 0)
        goto do_orig_stat;

    if (unlikely(!memcmp(path, su_path, sizeof(su_path)))) {
        old_cred = override_creds(ksu_cred);
        if (is_ksud_exists()) {
            orig_filename = *filename_user;
            *filename_user = ksud_user_path();
            ret = ksu_syscall_table[orig_nr](regs);
            revert_creds(old_cred);
            *filename_user = orig_filename;
            return ret;
        }
        revert_creds(old_cred);
    }

do_orig_stat:
    return ksu_syscall_table[orig_nr](regs);
}
'''

def span(src, sig):
    i = src.find(sig)
    if i < 0:
        raise SystemExit('找不到函数签名: ' + sig)
    # 从签名后的第一个 '{' 起做大括号配平（跳过注释字符串里的括号：本文件这两个函数体内没有花括号字符）
    j = src.find('{', i)
    d = 0
    k = j
    while k < len(src):
        c = src[k]
        if c == '{':
            d += 1
        elif c == '}':
            d -= 1
            if d == 0:
                return i, k + 1
        k += 1
    raise SystemExit('大括号配平失败: ' + sig)

for sig, new in (
    ('long ksu_handle_faccessat_sucompat(int orig_nr, struct pt_regs *regs)', NEW_FA),
    ('long ksu_handle_stat_sucompat(int orig_nr, struct pt_regs *regs)', NEW_FS),
):
    a, b = span(s, sig)
    old = s[a:b]
    nprint = old.count('pr_info')
    s = s[:a] + new + s[b:]
    print('%s: 原段 %d 字节 / %d 条 pr_info ⇒ 新段 %d 字节' % (sig.split('(')[0].split()[-1], len(old), nprint, len(new)))

open(P, 'w', encoding='utf-8', errors='surrogateescape').write(s)
print('写回', P, '总字节', len(s))
