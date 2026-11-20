#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rc22：把 sucompat 那条"唯一还没审过的内核路"变成**一发窗口内可二分**的形状（md §6.41）。

第十八发(rc21)拿到的硬事实：
  - `KSUBEAT A readback: slot=42 ... OK` ⇒ **sys_call_table 那笔写第一次真落地**。
  - `F sys_enter fired#1..8: id=… has_hook=0` ⇒ tracepoint 在真机**会为任务触发**；
    `ti_flags=0x4000400/0x4000c00` ⇒ bit10 = `_TIF_SYSCALL_TRACEPOINT` 确实在里面。
  - `F2 redirect: id=221 -> 42 x8_stash=0xdd` + `B dispatcher entered: syscallno=42 regs[8]=221`
    ⇒ **改道、存档、进调度器、还原号、回落原实现全通**；而且 833.47~833.69 之间
    `sh` 的一长串子进程(18260..18270)都走了这条路，设备**没炸** ⇒ 机制本身稳。
  - `registered syscall hook for nr=221` ⇒ 本树 `__NR_execve` = **221**（不是我之前一直写的 179）。
  - 崩的是**下一段**：日志停在 `sumark` 那一行，之后整机重启 ⇒
    只可能是 `ksu_handle_execve_sucompat_common()` 里 su 命中之后的那段
    （`get_unused_fd_flags`/`override_creds(ksu_cred)`+`filp_open`/`userspace_stack_buffer`/
     `escape_with_root_profile()`/嵌套 `ksu_syscall_table[__NR_execveat](regs)`）。
  - 同一条可疑线索：`Failed to cache kernel su domain SID: -22`、`Failed to cache ksu_file SID: -22`
    ⇒ `ksu_cred` 的 SELinux sid 很可能没取到（sid=0/无效），而 sucompat 正好
    `override_creds(ksu_cred)` 并 `escape_with_root_profile()` 用它 ⇒ 头号嫌疑。

⇒ 本脚本做两件事，让"哪一行炸"变成一次开机就能读出来的东西：
  ① 在 su 分支里插 **SU0..SU4** 五行"动手之前"的内核打印（配合脚本里的 dmesg 活落盘 = 崩溃前最后一条就是死点）；
  ② 加两个 **运行时可写** 的闸门 `ksu_no_escape` / `ksu_no_cred_override`（`0644`），
     于是同一 boot 里能按"最保守 → 全开"的顺序连做三次 su，一次把变量分干净。
幂等：tag = KSUBEAT SU0..SU4 / ksu_no_escape / ksu_no_cred_override。
"""
import io
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"
F = M + "/feature/sucompat.c"

EDITS = [
    ("SU-PARAM",
     'bool ksu_su_compat_enabled __read_mostly = true;\n',
     'bool ksu_su_compat_enabled __read_mostly = true;\n'
     '\n'
     '/* ★第十八发崩在 su 命中之后的那段，所以这两条闸门做成**运行时可写**(0644)：\n'
     ' *    echo 1 > /sys/module/kernelsu/parameters/ksu_no_escape\n'
     ' *  ⇒ 同一个 boot 里可以按 "两条都开 → 只关 cred → 全开" 的顺序做三次 su，\n'
     ' *    一次窗口就把变量分干净，不必一发一 boot。 */\n'
     'bool ksu_no_escape __read_mostly = false;\n'
     'module_param(ksu_no_escape, bool, 0644);\n'
     'MODULE_PARM_DESC(ksu_no_escape, "sucompat: 跳过 escape_with_root_profile()，只测改道+execveat 重写");\n'
     'bool ksu_no_cred_override __read_mostly = false;\n'
     'module_param(ksu_no_cred_override, bool, 0644);\n'
     'MODULE_PARM_DESC(ksu_no_cred_override, "sucompat: filp_open(/data/adb/ksud) 不改 cred(ksu_cred 的 sid 缓存失败过 -22)");\n'),

    ("SU0",
     '    pr_info("sys_execve su found\\n");\n',
     '    pr_info("KSUBEAT SU0 su found: pid=%d comm=%s uid=%u no_escape=%d no_cred_override=%d\\n",\n'
     '            current->pid, current->comm, current_uid().val, ksu_no_escape ? 1 : 0,\n'
     '            ksu_no_cred_override ? 1 : 0);\n'),

    ("SU1",
     '    old_cred = override_creds(ksu_cred);\n'
     '    ksud_file = filp_open(KSUD_PATH, O_PATH, 0);\n'
     '    revert_creds(old_cred);\n',
     '    pr_info("KSUBEAT SU1 before filp_open: tmp_fd=%d no_cred_override=%d\\n", tmp_fd,\n'
     '            ksu_no_cred_override ? 1 : 0);\n'
     '    if (ksu_no_cred_override) {\n'
     '        old_cred = NULL;\n'
     '        ksud_file = filp_open(KSUD_PATH, O_PATH, 0);\n'
     '    } else {\n'
     '        old_cred = override_creds(ksu_cred);\n'
     '        ksud_file = filp_open(KSUD_PATH, O_PATH, 0);\n'
     '        revert_creds(old_cred);\n'
     '        old_cred = NULL;\n'
     '    }\n'),

    ("SU2",
     '    ret = escape_with_root_profile();\n'
     '    if (ret) {\n'
     '        pr_err("escape_with_root_profile failed: %ld\\n", ret);\n'
     '    }\n',
     '    if (ksu_no_escape) {\n'
     '        pr_info("KSUBEAT SU2 skip escape_with_root_profile pid=%d uid=%u\\n", current->pid,\n'
     '                current_uid().val);\n'
     '        ret = 0;\n'
     '    } else {\n'
     '        pr_info("KSUBEAT SU2 before escape_with_root_profile pid=%d uid=%u\\n", current->pid,\n'
     '                current_uid().val);\n'
     '        ret = escape_with_root_profile();\n'
     '        if (ret) {\n'
     '            pr_err("escape_with_root_profile failed: %ld\\n", ret);\n'
     '        }\n'
     '    }\n'),

    ("SU3",
     '    ret = ksu_syscall_table[__NR_execveat](regs);\n',
     '    pr_info("KSUBEAT SU3 before nested execveat: fd=%d uid=%u euid=%u parm2=%px parm5=%lu\\n",\n'
     '            (int)PT_REGS_SYSCALL_PARM1(regs), current_uid().val, current_euid().val,\n'
     '            (void *)regs->__PT_PARM2_REG, (unsigned long)regs->__PT_PARM5_REG);\n'
     '    ret = ksu_syscall_table[__NR_execveat](regs);\n'
     '    pr_info("KSUBEAT SU4 after nested execveat: ret=%ld uid=%u\\n", ret, current_uid().val);\n'),
]

s = io.open(F, encoding="utf-8", errors="replace").read()
n = 0
for tag, old, new in EDITS:
    probe = "KSUBEAT " + tag.split("-")[0] if tag != "SU-PARAM" else "ksu_no_escape"
    if probe in s:
        print("  = 已有, 跳过 %s" % tag)
        continue
    c = s.count(old)
    if c != 1:
        print("  !! 锚点 %s 命中 %d 次, 不动" % (tag, c))
        continue
    s = s.replace(old, new, 1)
    n += 1
    print("  + %s" % tag)
io.open(F, "w", encoding="utf-8", newline="\n").write(s)
print("写了 %d 处 -> %s" % (n, F))
