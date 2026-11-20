#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给 KSU 的 arm64 hook 层装**自检**(md §6.31)。第十发证明 stage=7 装得上且设备活着，
但被 mark 的任务那 5 个被 hook 的 syscall 全返 -ENOSYS。剩下的未知只有一条：
  **`sys_call_table[ni_slot]` 那笔写到底落没落到真表上**。
这一发设备是活的 ⇒ dmesg 会被 post 脚本落进 /data 文件 ⇒ 把未知变成**一行日志**就行：
  A) `patch_syscall_table()` 写完**读回比对**(带两边地址)，不一致就 MISMATCH；
  B) 调度器**第一次被进到**时打一条 once(`syscallno` / `regs[8]` / pid / comm)
     ⇒ 有 B = 写落地了；没 B 而仍然 ENOSYS = 表项还是 ni_syscall(写没落/落错页)。
约束：唯一锚点、tag 幂等、**只加打印**(不改任何行为/返回值)。
"""
import io
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"
F = M + "/hook/arm64/syscall_hook.c"

A_OLD = ('        pr_err("patch syscall %d failed\\n", nr);\n'
         '        return -EIO;\n'
         '    }\n')
A_NEW = A_OLD + ('    pr_info("KSUBEAT A readback: slot=%d want=%px got=%px %s\\n", nr, (void *)fn,\n'
                 '            (void *)READ_ONCE(ksu_syscall_table[nr]),\n'
                 '            (void *)ksu_syscall_table[nr] == (void *)fn ? "OK" : "MISMATCH");\n')

B_OLD = 'static long __nocfi ksu_syscall_dispatcher(const struct pt_regs *regs)\n{\n'
B_NEW = B_OLD + ('    pr_info_once("KSUBEAT B dispatcher entered: syscallno=%d regs[8]=%d pid=%d comm=%s\\n",\n'
                 '\t\t regs->syscallno, (int)PT_REGS_ORIG_SYSCALL(regs), current->pid, current->comm);\n')

s = io.open(F, encoding="utf-8", errors="replace").read()
n = 0
for tag, old, new in (("KSUBEAT A", A_OLD, A_NEW), ("KSUBEAT B", B_OLD, B_NEW)):
    if tag in s:
        print("  = 已有, 跳过 %s" % tag)
        continue
    c = s.count(old)
    if c != 1:
        print("  !! 锚点命中 %d 次, 不动: %s" % (c, tag))
        continue
    s = s.replace(old, new, 1)
    n += 1
    print("  + %s" % tag)
io.open(F, "w", encoding="utf-8", newline="\n").write(s)
print("写了 %d 处 -> %s" % (n, F))
