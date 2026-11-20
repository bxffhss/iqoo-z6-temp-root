#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""调度器三条 -ENOSYS 分支各加一行打印（md §6.36）。

第十五发的现象是"开闸门 7 ⇒ adbd 的 execve 变 -ENOSYS"。`KSUBEAT B`(只在第一次进调度器时打)
能告诉我们"有没有进调度器、syscallno/regs[8] 各是多少"，但**分不清是哪条分支把调用判死的**：
  E1 `regs->syscallno != ksu_dispatcher_nr`  ⇒ 表项不是我们的槽(改道没生效/槽号不对)
  E2 `regs->syscallno == orig_nr`            ⇒ `regs[8]` 里取回来的"原始号"就是 42(存档失败)
  E3 走到最后(=该 nr 没挂 hook 或 nr 越界)     ⇒ 改道与存档都对，是 hook 表/号域的问题
⇒ 三行打印 + 限频(ratelimited)就一发窗口定案，不会再靠猜。
幂等：靠 tag KSUBEAT E1/E2/E3。
"""
import io
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"
F = M + "/hook/arm64/syscall_hook.c"

EDITS = [
    ("E1",
     "    if (regs->syscallno != ksu_dispatcher_nr)\n        return -ENOSYS;\n",
     "    if (regs->syscallno != ksu_dispatcher_nr) {\n"
     '        pr_info_ratelimited("KSUBEAT E1: syscallno=%d != dispatcher_nr=%d\\n",\n'
     "                regs->syscallno, ksu_dispatcher_nr);\n"
     "        return -ENOSYS;\n    }\n"),
    ("E2",
     "    if (regs->syscallno == orig_nr)\n        return -ENOSYS;\n",
     "    if (regs->syscallno == orig_nr) {\n"
     '        pr_info_ratelimited("KSUBEAT E2: regs[8] 取回的 orig_nr=%d 就是槽号(存档没生效) pid=%d\\n",\n'
     "                orig_nr, current->pid);\n"
     "        return -ENOSYS;\n    }\n"),
    ("E3",
     "    return -ENOSYS;\n}\n",
     '    pr_info_ratelimited("KSUBEAT E3: orig_nr=%d 没挂 hook 或越界(hook=%px) pid=%d comm=%s\\n",\n'
     "            orig_nr, (void *)READ_ONCE(syscall_hooks[orig_nr >= 0 && orig_nr < __NR_syscalls ? orig_nr : 0]),\n"
     "            current->pid, current->comm);\n"
     "    return -ENOSYS;\n}\n"),
]

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
    print("  + %s" % tag)
io.open(F, "w", encoding="utf-8", newline="\n").write(s)
print("写了 %d 处 -> %s" % (n, F))
