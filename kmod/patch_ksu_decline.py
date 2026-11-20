#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rc24：让 su 分支的**每一条"放弃"路径都留下原因**（md §6.44）。

第二十发(rc23, 不传 allow_shell)的事实：设备活着、表写与改道照旧全绿
(`A readback OK` / `F2 redirect` / `B dispatcher entered` / `G mark` 父子两条都在)
但 `KSUBEAT SU0..SU4` 与 `sys_execve su found` **全 0**，子进程拿到的是真 execve 的 ENOENT。
⇒ 现在**分不清**是"根本没改道到 hook"还是"hook 进去了、在某个判据前放弃了"，
因为 `ksu_handle_execve_sucompat_common()` 的 5 条 `goto do_orig_execve` **一条打印都没有**。

同时读穿了一条会改变整个打法的代码事实(`policy/allowlist.c:__ksu_is_allow_uid()`)：
    if (forbid_system_uid(uid)) return false;     // uid < 10000 直接不看名单
⇒ **uid 2000(shell) 即使在 .allowlist 里也不可能有 su**，它只能靠 `allow_shell=1`；
   而 `allow_shell=1` 又必然把 root profile 短路成 `default_root_profile`(§6.42)，
   第十八/十九发正是这个组合死掉的。**app uid(10284 ≥ 10000)不受这条限制** ⇒
   "最后只用 KernelSU 授权"这个目标本来就该走 10284，不该纠结 shell。
⇒ 所以这一发把判据全押在 uid 10284 上，并让每次放弃都点名原因。

★只在"这个 uid 本来有资格拿 su"时才打印 ⇒ 根 shell 那些 execve 风暴(uid 0 无资格)不会把日志刷爆，
  而我们真正关心的那一次一定有行。
幂等 tag：KSUBEAT SD0..SD5。
"""
import io
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"
F = M + "/feature/sucompat.c"

EDITS = [
    ("SD-INIT",
     '    if (execveat && ((int)PT_REGS_SYSCALL_PARM1(regs) != AT_FDCWD || (int)PT_REGS_PARM5(regs) != 0))\n',
     '    path[0] = 0; /* KSUBEAT SD-INIT：任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */\n'
     '    if (execveat && ((int)PT_REGS_SYSCALL_PARM1(regs) != AT_FDCWD || (int)PT_REGS_PARM5(regs) != 0))\n'),

    ("SD0",
     '    if (unlikely(!filename_user))\n        goto do_orig_execve;\n',
     '    if (unlikely(!filename_user)) {\n'
     '        pr_info("KSUBEAT SD0 decline: filename_user=NULL pid=%d uid=%u\\n",\n'
     '                current->pid, current_uid().val);\n'
     '        goto do_orig_execve;\n'
     '    }\n'),

    ("SD1",
     '    if (!ksu_is_allow_uid_for_current(current_uid().val))\n        goto do_orig_execve;\n',
     '    if (!ksu_is_allow_uid_for_current(current_uid().val)) {\n'
     '        /* ★这条就是 uid 2000 的死刑：__ksu_is_allow_uid() 里 `forbid_system_uid(uid)`\n'
     '         *   (uid < 10000 直接 return false，**连名单都不查**) ⇒ shell 只能靠 allow_shell=1。 */\n'
     '        if (current_uid().val < 10000)\n'
     '            pr_info("KSUBEAT SD1 decline: uid=%u 是 system uid(forbid_system_uid)，名单不算\\n",\n'
     '                    current_uid().val);\n'
     '        goto do_orig_execve;\n'
     '    }\n'),

    ("SD2",
     '    if (ret < 0) {\n'
     '        pr_warn("Access filename when execve failed: %ld", ret);\n'
     '        goto do_orig_execve;\n'
     '    }\n',
     '    if (ret < 0) {\n'
     '        pr_warn("KSUBEAT SD2 decline: strncpy_from_user=%ld pid=%d\\n", ret, current->pid);\n'
     '        goto do_orig_execve;\n'
     '    }\n'),

    ("SD3",
     '    if (likely(memcmp(path, su_path, sizeof(su_path))))\n        goto do_orig_execve;\n',
     '    if (likely(memcmp(path, su_path, sizeof(su_path)))) {\n'
     '        /* 路径不是 su ⇒ 这是正常 exec，本来就不该拦。低频才印：只有"这个 uid 有资格"时才印。 */\n'
     '        if (ksu_is_allow_uid(current_uid().val))\n'
     '            pr_info("KSUBEAT SD3 decline: 路径不是 su: [%s] pid=%d uid=%u\\n", path, current->pid,\n'
     '                    current_uid().val);\n'
     '        goto do_orig_execve;\n'
     '    }\n'),

    ("SD4",
     '    tmp_fd = get_unused_fd_flags(O_CLOEXEC);\n'
     '    if (tmp_fd < 0) {\n'
     '        pr_err("alloc tmp fd err: %d\\n", tmp_fd);\n'
     '        goto do_orig_execve;\n'
     '    }\n',
     '    pr_info("KSUBEAT SD4 su 命中，开始拿 fd: pid=%d uid=%u\\n", current->pid, current_uid().val);\n'
     '    tmp_fd = get_unused_fd_flags(O_CLOEXEC);\n'
     '    if (tmp_fd < 0) {\n'
     '        pr_err("alloc tmp fd err: %d\\n", tmp_fd);\n'
     '        goto do_orig_execve;\n'
     '    }\n'),

    ("SD5",
     'do_orig_execve:\n    return ksu_syscall_table[orig_nr](regs);\n}\n',
     'do_orig_execve:\n'
     '    if (ksu_is_allow_uid(current_uid().val))\n'
     '        pr_info("KSUBEAT SD5 do_orig_execve: nr=%d pid=%d uid=%u path=[%s]\\n", orig_nr,\n'
     '                current->pid, current_uid().val, path);\n'
     '    return ksu_syscall_table[orig_nr](regs);\n}\n'),
]

# 另外把 F 的"前 8 次"上限改成"前 8 次 或 任何 execve"，否则风暴会把 execve 那几条挤掉
FM = M + "/hook/syscall_hook_manager.c"

s = io.open(F, encoding="utf-8", errors="replace").read()
n = 0
for tag, old, new in EDITS:
    if "KSUBEAT " + tag in s:
        print("  = 已有, 跳过 %s" % tag)
        continue
    c = s.count(old)
    if c != 1:
        print("  !! 锚点 %s 命中 %d 次, 不动" % (tag, c))
        continue
    s = s.replace(old, new, 1)
    n += 1
    print("  + %s (sucompat.c)" % tag)
io.open(F, "w", encoding="utf-8", newline="\n").write(s)

t = io.open(FM, encoding="utf-8", errors="replace").read()
old_f = '        if (nfired <= 8)\n'
new_f = '        if (nfired <= 8 || id == __NR_execve || id == __NR_execveat)\n'
if "id == __NR_execve ||" in t:
    print("  = 已有, 跳过 F-CAP")
elif t.count(old_f) == 1:
    t = t.replace(old_f, new_f, 1)
    io.open(FM, "w", encoding="utf-8", newline="\n").write(t)
    n += 1
    print("  + F-CAP (syscall_hook_manager.c: execve 无条件印)")
else:
    print("  !! F-CAP 锚点命中 %d 次, 不动" % t.count(old_f))
print("写了 %d 处" % n)
