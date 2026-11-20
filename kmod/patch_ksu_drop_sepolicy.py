#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""patch_ksu_drop_sepolicy.py —— 砍掉 KSU 的 6.x SELinux 策略注入层（§6.6 的决定）。

依据（一手 grep，不是猜）：`selinux/selinux.c` 里 `grep -nE 'sepolicy_|rules_'` **为空**，
全项目也只有 `supercall/dispatch.c:150` 提到 `struct ksu_set_sepolicy_cmd`(一个命令结构体)
⇒ 从 Kbuild 剔除 rules.o/sepolicy.o 预计**不需要补桩**；若链接期报 undefined symbol 再按符号补。
顺带修 `pkg_observer.c`：本树 `handle_event` 是 8 参数(没有 dir)，我上一版包装多带一个参数。

可逆：`git -C /root/k/ksu checkout -- kernel/Kbuild kernel/manager/pkg_observer.c`
"""
import re, sys, os

KSU = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"
DRY = "--dry-run" in sys.argv

EDITS = [
    ("Kbuild", r"^kernelsu-objs \+= selinux/rules\.o$",
     "# kernelsu-objs += selinux/rules.o   # 剔除: 依赖 6.x SELinux SS 内部结构(5.4 无) — md §6.6",
     "剔 rules.o"),
    ("Kbuild", r"^kernelsu-objs \+= selinux/sepolicy\.o$",
     "# kernelsu-objs += selinux/sepolicy.o # 剔除: 同上(filename_trans_key/stypes/sidtab)",
     "剔 sepolicy.o"),
    # 我上一版包装按 9 参数写的(带 dir)，本树是 8 参数 ⇒ 去掉 dir
    ("manager/pkg_observer.c", r"struct inode \*dir, const struct qstr \*file_name, u32 cookie,\n\t\t\t  struct fsnotify_iter_info \*iter_info\)",
     "const struct qstr *file_name, u32 cookie,\n\t\t\t  struct fsnotify_iter_info *iter_info)",
     "handle_event 去 dir 参数"),
]

for rel, pat, rep, label in EDITS:
    p = os.path.join(KSU, rel)
    s = open(p, encoding="utf-8", errors="replace").read()
    if rep in s:
        print("跳过(已打过) %-24s %s" % (rel, label)); continue
    n = len(re.findall(pat, s, flags=re.M))
    if n != 1:
        print("!! %-24s %s: 锚点命中 %d 次(要求 1) ⇒ 不动" % (rel, label, n)); continue
    s = re.sub(pat, rep, s, count=1, flags=re.M)
    print("已改 %-26s %s" % (rel, label))
    if not DRY:
        open(p, "w", encoding="utf-8", newline="\n").write(s)
