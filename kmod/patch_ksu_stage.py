#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给 KSU 装一根**分级闸门**(stage ladder)，用途：本设备取不到崩溃后日志
(实测 /sys/fs/pstore 是空目录 ⇒ md §6.26)，只能靠"崩之前最后一个已 sync 的动作"定位 ⇒
每个可疑子系统**入口**挂一道 `if (!ksu_stage_ok(N)) return;`，加载时 `insmod ... ksu_stage=N`。

★第五发的教训(§6.27)：只关 init **不够** —— `rmmod` 会把"从没初始化过的东西"再拆一遍：
  `ksu_supercalls_exit()` 无条件 `unregister_kprobe(&reboot_kp)`(没注册过)，
  `ksu_observer_exit()` 无条件 `fsnotify_put_group(g)`(g==NULL) ⇒ 当场 oops。
  那一发的设备就是这么重启的，**不是** KSU 的 init 炸的。⇒ exit 侧也挂**同编号**的闸门。

设计约束(踩过的账，见 md §6.11/§6.12)：只用**唯一锚点**(函数定义行)、不按行号切、
每条编辑自带 tag 做幂等、闸门一律放函数**入口**(不改控制流/返回值语义)。
"""
import io
import re
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"

# (文件, 锚点正则[必须只命中一次], 插入体, tag, 说明)
EDITS = [
    ("hook/arm64/syscall_hook.c",
     r"void __init ksu_syscall_hook_init\(void\)\n\{\n",
     '    if (!ksu_stage_ok(2)) { pr_info("KSUSTEP 2 skip: syscall_hook_init(sys_call_table+stop_machine)\\n"); return; }\n',
     "KSUSTEP 2 skip", "stage2 = 写 sys_call_table 装 dispatcher(停机器+fixmap)"),
    ("supercall/supercall.c",
     r"void __init ksu_supercalls_init\(void\)\n\{\n    int rc;\n",
     '    if (!ksu_stage_ok(4)) { pr_info("KSUSTEP 4 skip: supercalls kprobe on reboot\\n"); return; }\n',
     "KSUSTEP 4 skip", "stage4 = __arm64_sys_reboot 上挂 kprobe"),
    ("supercall/supercall.c",
     r"void __exit ksu_supercalls_exit\(void\)\n\{\n",
     '    if (!ksu_stage_ok(4)) { pr_info("KSUSTEP 4 exit-skip: 没注册过, 不去 unregister_kprobe\\n"); return; }\n',
     "KSUSTEP 4 exit-skip", "★exit 闸门: 防 unregister_kprobe(未注册)"),
    ("hook/syscall_hook_manager.c",
     r"void __init ksu_syscall_hook_manager_init\(void\)\n\{\n    int ret;\n",
     '    if (!ksu_stage_ok(7)) { pr_info("KSUSTEP 7 skip: hook_manager(tracepoint+setuid+sucompat)\\n"); return; }\n',
     "KSUSTEP 7 skip", "stage7 = 注册 sys_enter tracepoint / setuid hook / sucompat"),
    ("hook/syscall_hook_manager.c",
     r"void __exit ksu_syscall_hook_manager_exit\(void\)\n\{\n",
     '    if (!ksu_stage_ok(7)) { pr_info("KSUSTEP 7 exit-skip\\n"); return; }\n',
     "KSUSTEP 7 exit-skip", "★exit 闸门: 防拆没建过的 hook 表/sucompat"),
    ("manager/throne_tracker.c",
     r"void __init ksu_throne_tracker_init\(\)\n\{\n",
     '    if (!ksu_stage_ok(8)) { pr_info("KSUSTEP 8 skip: throne_tracker\\n"); return; }\n',
     "KSUSTEP 8 skip", "stage8 = 扫 /data/app 的跟踪器(会 iterate_dir)"),
    ("manager/pkg_observer.c",
     r"int ksu_observer_init\(void\)\n\{\n",
     '    if (!ksu_stage_ok(8)) { pr_info("KSUSTEP 8 skip: pkg_observer\\n"); return 0; }\n',
     "KSUSTEP 8 skip: pkg", "stage8 = fsnotify 观察者"),
    ("manager/pkg_observer.c",
     r"void __exit ksu_observer_exit\(void\)\n\{\n",
     '    if (!ksu_stage_ok(8)) { pr_info("KSUSTEP 8 exit-skip: 不对 NULL 的 group 放引用\\n"); return; }\n',
     "KSUSTEP 8 exit-skip", "★exit 闸门: fsnotify_put_group(NULL) 就是上一发的 oops"),
    ("selinux/selinux.c",
     r"(?m)^void setenforce\(bool enforce\)\n\{\n",
     '    if (!ksu_stage_ok(9)) { pr_info("KSUSTEP 9 skip: setenforce\\n"); return; }\n',
     "KSUSTEP 9 skip", "stage9 = 真把 MAC 打开(晚加载分支末尾会调)"),
]


def apply(path, pat, ins, tag, note):
    s = io.open(path, encoding="utf-8", errors="replace").read()
    if tag in s:
        print("  = 已有, 跳过  %-26s %s" % (path.split("/")[-1], tag))
        return
    n = len(re.findall(pat, s))
    if n != 1:
        print("  !! 锚点命中 %d 次, 不动: %s  (%s)" % (n, path, note))
        return
    s = re.sub(pat, lambda m: m.group(0) + ins, s, count=1)
    io.open(path, "w", encoding="utf-8", newline="\n").write(s)
    print("  + %-26s %s" % (path.split("/")[-1], note))


print("=== 分级闸门(init+exit) -> %s ===" % M)
for f, pat, ins, tag, note in EDITS:
    apply(M + "/" + f, pat, ins, tag, note)
print("完成。撤销：git -C %s checkout -- <上面这些文件>" % M)
