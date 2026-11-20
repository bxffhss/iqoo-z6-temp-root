#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rc16 自检(md §6.31)：第十发的现场证明 **init 全程跑完、dispatcher 装上、reboot kprobe 也注册成功**，
但 uid 0 调 `reboot(magic1,magic2)` 只拿到 EINVAL、**fd 没回来**，而且 dmesg 里
**一条 `install ksu fd` 都没有** ⇒ 未知收缩成一条：
   **`reboot_handler_pre()` 到底有没有被触发？它把 magic1/magic2 读成了什么？**
arm64 的 kprobe pre_handler 收到的是 **BRK 异常帧**的 pt_regs，所以 KSU 才要 `PT_REAL_REGS(regs)`
(= `(struct pt_regs *)regs->regs[0]`，即被 kprobe 的 syscall 包装函数的 arg0=系统调用 pt_regs)。
这条链上有三个可能断点，只能用一行打印区分 ⇒ 这里插**两条**打印(不改任何逻辑)：
   C1 在解引用 real_regs **之前**：只印两个指针(若 real_regs 是野指针，这一行仍能看到)
   C2 在读完 magic1/magic2 **之后**：印读到的值
有 C1 无 C2 ⇒ 解引用炸了(说明 PT_REAL_REGS 在本机不对)；两条都有但 magic 不对 ⇒ 取参偏移不对；
一条都没有 ⇒ kprobe 压根没触发(那要换 REBOOT_SYMBOL 的思路)。
"""
import io
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"
F = M + "/supercall/supercall.c"

C1_OLD = "    struct pt_regs *real_regs = PT_REAL_REGS(regs);\n"
C1_NEW = C1_OLD + ('    pr_info("KSUBEAT C1 reboot kprobe hit: frame=%px real_regs=%px frame_x0=%px\\n",\n'
                   '            regs, real_regs, (void *)regs->regs[0]);\n')

C2_OLD = "    int magic2 = (int)PT_REGS_PARM2(real_regs);\n"
C2_NEW = C2_OLD + ('    pr_info("KSUBEAT C2 magics: m1=%#x m2=%#x want=%#x/%#x arm_x0=%px x1=%#lx x3=%#lx\\n",\n'
                   '            magic1, magic2, KSU_INSTALL_MAGIC1, KSU_INSTALL_MAGIC2,\n'
                   '            (void *)real_regs->regs[0], (unsigned long)real_regs->regs[1],\n'
                   '            (unsigned long)real_regs->regs[3]);\n')

s = io.open(F, encoding="utf-8", errors="replace").read()
n = 0
for tag, old, new in (("KSUBEAT C1", C1_OLD, C1_NEW), ("KSUBEAT C2", C2_OLD, C2_NEW)):
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
