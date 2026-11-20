#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在 KSU 的 init 关键路径上插**细粒度脚印**(KSUBEAT 行)。见 md §6.28/§6.29：
本机没有 pstore 后端 ⇒ 崩在 init 里时唯一能拿住的东西 = "**崩溃前已被后台循环 sync 到 /data 的
内核日志尾**"。脚印越密，一发窗口就能定位到具体哪一句，而不是只定位到"哪个子系统"。
KSU 自带的天然脚印已经覆盖了几个点(`sys_call_table=0x…`/`dispatcher installed at slot N`/
`reboot kprobe registered successfully`/`hook_manager: register_%s kretprobe: %d`)，这里只补空档。

约束同 §6.11：唯一锚点、每条自带 tag 幂等、**只插 pr_info 一行**(不改控制流/不加语句)。
"""
import io
import re
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"

# (文件, 锚点正则[必须只命中一次], 要插的行, after=?, tag, 说明)
#   after=True  ⇒ 插在锚点之后(锚点通常是"函数定义行 + {\n")
#   after=False ⇒ 插在锚点之前(锚点通常是一条完整语句)
EDITS = [
    ("hook/syscall_hook_manager.c",
     r"    ret = ksu_sys_enter_tp_register\(ksu_sys_enter_handler\);",
     '    pr_info("KSUBEAT M2 before sys_enter tracepoint register\\n");\n', False, "M2",
     "tracepoint 注册前"),
    ("hook/syscall_hook_manager.c",
     r"    ksu_setuid_hook_init\(\);",
     '    pr_info("KSUBEAT M3 before setuid_hook_init/sucompat_init\\n");\n', False, "M3",
     "setuid hook(=kernel_umount_init) + sucompat_init 前"),
    ("feature/kernel_umount.c",
     r"(?m)^void __init ksu_kernel_umount_init\(void\)\n\{\n",
     '    pr_info("KSUBEAT M4 enter kernel_umount_init\\n");\n', True, "M4",
     "kernel_umount init 入口(它也是 fsnotify/inotify 用户)"),
    ("feature/sucompat.c",
     r"(?m)^void __init ksu_sucompat_init\(\)\n\{\n",
     '    pr_info("KSUBEAT M5 enter sucompat_init\\n");\n', True, "M5",
     "sucompat init 入口"),
    ("supercall/supercall.c",
     r"    rc = register_kprobe\(&reboot_kp\);",
     '    pr_info("KSUBEAT M6 before kprobe on __arm64_sys_reboot\\n");\n', False, "M6",
     "reboot kprobe 前"),
    ("hook/arm64/syscall_hook.c",
     r"    ksu_syscall_table_hook\(ksu_dispatcher_nr, \(syscall_fn_t\)ksu_syscall_dispatcher, NULL\);",
     '    pr_info("KSUBEAT S2b before sys_call_table write\\n");\n', False, "S2b",
     "写 sys_call_table 前(它里面是 stop_machine+fixmap)"),
]

# core/init.c 晚加载分支：逐句脚印(区间端点唯一 ⇒ 只在区间内部动手)
LATE_A = 'pr_info("late load mode, skipping kprobe hooks\\n");'
LATE_CALLS = [
    "apply_kernelsu_rules();", "cache_sid();", "setup_ksu_cred();", "escape_to_root_for_init();",
    "ksu_allowlist_init();", "ksu_load_allow_list();", "ksu_syscall_hook_manager_init();",
    "ksu_throne_tracker_init();", "ksu_observer_init();", "track_throne(false);",
    "ksu_file_wrapper_init();",
]
LATE_END = "ksu_file_wrapper_init();"


def apply(path, pat, line, after, tag, note):
    s = io.open(path, encoding="utf-8", errors="replace").read()
    if "KSUBEAT " + tag in s:
        print("  = 已有, 跳过 %s (%s)" % (path.split("/")[-1], tag))
        return
    n = len(re.findall(pat, s))
    if n != 1:
        print("  !! 锚点命中 %d 次, 不动: %s (%s)" % (n, path, note))
        return
    if after:
        s = re.sub(pat, lambda m: m.group(0) + line, s, count=1)
    else:
        s = re.sub(pat, lambda m: line + m.group(0), s, count=1)
    io.open(path, "w", encoding="utf-8", newline="\n").write(s)
    print("  + %-26s %s" % (path.split("/")[-1], note))


def apply_late(path):
    s = io.open(path, encoding="utf-8", errors="replace").read()
    if "KSUBEAT L" in s:
        print("  = 已有, 跳过 core/init.c 晚加载脚印")
        return
    if s.count(LATE_A) != 1:
        print("  !! 晚加载区间起点命中 %d 次, 不动" % s.count(LATE_A))
        return
    i = s.index(LATE_A) + len(LATE_A)
    j = s.index(LATE_END, i) + len(LATE_END)
    seg = s[i:j]
    for k, call in enumerate(LATE_CALLS):
        c = seg.count(call)
        if c != 1:
            print("  !! 区间内 %s 命中 %d 次, 跳过这句" % (call, c))
            continue
        seg = seg.replace(call, 'pr_info("KSUBEAT L%d before %s\\n");\n    %s'
                          % (k, call.rstrip(";"), call), 1)
    s = s[:i] + seg + s[j:]
    io.open(path, "w", encoding="utf-8", newline="\n").write(s)
    print("  + core/init.c  晚加载分支 %d 句脚印" % len(LATE_CALLS))


print("=== 细粒度脚印 -> %s ===" % M)
for f, pat, line, after, tag, note in EDITS:
    apply(M + "/" + f, pat, line, after, tag, note)
apply_late(M + "/core/init.c")
print("完成。撤销：git -C %s checkout -- <上面这些文件>" % M)
