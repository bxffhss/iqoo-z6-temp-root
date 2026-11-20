#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给 KSU 的 5 个 syscall hook 各加一位开关 `ksu_hook_mask`（md §6.36）。

为什么需要它：第十五发(rc18, thread_info 已修)证明**只要开闸门 7，adbd 就会被打标**——
因为注册 sys_enter tracepoint 时内核会走 tracepoint 的 regfunc(syscall_regfunc)，
而我们正好在 syscall_regfunc 上挂了 kretprobe，它的 handler 会 `ksu_mark_running_process_locked()`
⇒ 存量任务(含 adbd/zygote)当场全部带标。于是 dispatcher 一旦还有问题，
`execve` 立刻变 -ENOSYS ⇒ adb shell/pull/reboot 全废，只能长按电源(第十、十一、十五发各中过一次)。

⇒ 想要"能测 dispatcher 又不弄死 adb"，就必须**只挂非 execve 的那几个 hook**：
   `newfstatat`/`faccessat`/`setresuid` 被 adbd 高频调用 ⇒ 只要它们进调度器，
   `KSUBEAT B dispatcher entered: syscallno=… regs[8]=…` 就会打出来 ⇒ 直接看到
   "原始 syscall 号到底从哪儿取回来"，而 adb 不会死(它的 execve 没被改道)。

位定义（按 syscall_hook_manager.c 里那 5 行的源码顺序，写死在注释里，别靠记忆）：
   bit0 = setresuid   bit1 = execve   bit2 = execveat   bit3 = newfstatat   bit4 = faccessat
默认 0x1f = 全开(=上游行为)。安全档 `ksu_hook_mask=0x15`(=10101b：不开 execve/execveat)。
幂等：靠 tag `ksu_hook_mask &`。
"""
import io
import re
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"
F = M + "/hook/syscall_hook_manager.c"

BITS = [
    ("ksu_register_syscall_hook(__NR_setresuid, ksu_hook_setresuid);", 0),
    ("ksu_register_syscall_hook(__NR_execve, ksu_hook_execve);", 1),
    ("ksu_register_syscall_hook(__NR_execveat, ksu_hook_execveat);", 2),
    ("ksu_register_syscall_hook(__NR_newfstatat, ksu_hook_newfstatat);", 3),
    ("ksu_register_syscall_hook(__NR_faccessat, ksu_hook_faccessat);", 4),
]

s = io.open(F, encoding="utf-8", errors="replace").read()
if "ksu_hook_mask &" in s:
    print("  = 已有, 跳过 %s" % F)
    sys.exit(0)

n = 0
for call, bit in BITS:
    if s.count(call) != 1:
        print("  !! 锚点命中 %d 次, 不动: %s" % (s.count(call), call))
        continue
    s = s.replace(call, "if (ksu_hook_mask & (1U << %d)) { %s }" % (bit, call), 1)
    n += 1
    print("  + bit%d  %s" % (bit, call[:52]))

io.open(F, "w", encoding="utf-8", newline="\n").write(s)
print("改了 %d 处 -> %s" % (n, F))
