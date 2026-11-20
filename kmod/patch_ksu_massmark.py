#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""加一个 `ksu_mass_mark` 开关（默认 1=上游行为；0=**禁止大面积打标**）——md §6.36。

动机（一手，来自第十五发）：开闸门 7 之后 adb 立刻全灭(`execve`/`newfstatat` 变 -ENOSYS)，
因为注册 `sys_enter` tracepoint 会走该 tracepoint 的 regfunc(=`syscall_regfunc`)，
而我们**正好在 syscall_regfunc 上挂了 kretprobe**，它的 handler 第一件事就是
`ksu_mark_running_process_locked()` ⇒ 存量任务里所有 `uid==2000`/`pid==1`/zygote/已授权 uid
**当场全部被打标** ⇒ adbd 的 execve 也被改道进调度器 ⇒ 调度器一有问题，adb shell/pull/reboot 全废，
只能长按电源(第十/十一/十五发各中一次)。

我们要的是"**只给我要测的那个进程打标**"：
  · 大面积打标(全表遍历)关掉；
  · `KSU_IOCTL_MANAGE_MARK` 的 `op=2 mark <pid>` / `op=1 get <pid>` 照常可用 ⇒
    窗口脚本先给**自己**打标(fork 出来的 su 测试子进程继承标记)，adbd 始终不带标；
  ⇒ 于是 dispatcher 到底哪一步不对，能安全地用 `KSUBEAT B` 打印出来，而不会再把设备打死。

幂等：靠 tag `ksu_mass_mark`。锚点=函数定义行(唯一)。
"""
import io
import re
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"

# 2) tp_marker.c 里三处大面积打标各加一道门
EDITS = [
    ("hook/tp_marker.c",
     r"static void handle_process_mark\(bool mark\)\n\{\n    struct task_struct \*p, \*t;\n",
     '    if (!ksu_mass_mark) { pr_info("tp_marker: mass mark 被 ksu_mass_mark=0 关掉\\n"); return; }\n',
     "ksu_mass_mark"),
    ("hook/tp_marker.c",
     r"void ksu_mark_running_process_locked\(void\)\n\{\n    struct task_struct \*p, \*t;\n",
     '    if (!ksu_mass_mark) { pr_info("tp_marker: mark_running_locked 被 ksu_mass_mark=0 关掉\\n"); return; }\n',
     "ksu_mass_mark"),
]


def apply(path, pat, ins, tag):
    s = io.open(path, encoding="utf-8", errors="replace").read()
    if tag in s and path.endswith("tp_marker.c"):
        print("  = 已有, 跳过 %s" % path.split("/")[-1])
        return
    n = len(re.findall(pat, s))
    if n != 1:
        print("  !! 锚点命中 %d 次, 不动: %s" % (n, path))
        return
    s = re.sub(pat, lambda m: m.group(0) + ins, s, count=1)
    io.open(path, "w", encoding="utf-8", newline="\n").write(s)
    print("  + %s" % path.split("/")[-1])


d = io.open(D, encoding="utf-8", errors="replace").read()
if "ksu_mass_mark" in d:
    print("  = dev_syms.c 已有, 跳过")
elif d.count(PARAM_ANCHOR) == 1:
    io.open(D, "w", encoding="utf-8", newline="\n").write(d.replace(PARAM_ANCHOR, PARAM_NEW, 1))
    print("  + dev_syms.c 参数")
else:
    print("  !! dev_syms.c 锚点不唯一, 不动")

for f, pat, ins, tag in EDITS:
    apply(M + "/" + f, pat, ins, tag)
print("完成 -> %s" % M)
