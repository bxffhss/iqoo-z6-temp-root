#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""patch_ksu_54.py —— KSU 的 A 堆机械修正（只两处，都在 pkg_observer/app_profile）。

纪律：唯一文本锚点(不按行号)、幂等(打过的文件跳过)、可回滚(`git -C /root/k/ksu checkout -- <文件>`)。
不动 `selinux/sepolicy.c`（那是 §6.5 的 C 堆，等用户拍板"重写 vs 砍特性"）。
"""
import re, sys, os

KSU = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"
DRY = "--dry-run" in sys.argv

EDITS = [
    # --- 1) fsnotify: 本树 5.4 只有 handle_event(group, inode, mask, data, data_type,
    #          dir, file_name, cookie, iter_info)，没有 6.x 的 handle_inode_event(mark, ...)。
    #          他们的函数体只用到 file_name 与 mask ⇒ 纯签名降回 5.4 即可，逻辑一行不改。
    ("manager/pkg_observer.c",
     r"static int ksu_handle_inode_event\(struct fsnotify_mark \*mark, u32 mask, struct inode \*inode, struct inode \*dir,\n( *)const struct qstr \*file_name, u32 cookie\)",
     "static int ksu_handle_inode_event(struct fsnotify_group *group, struct inode *inode,\n"
     "\t\t\t  u32 mask, const void *data, int data_type,\n"
     "\t\t\t  struct inode *dir, const struct qstr *file_name, u32 cookie,\n"
     "\t\t\t  struct fsnotify_iter_info *iter_info)",
     "handle_event 签名降回 5.4"),
    ("manager/pkg_observer.c",
     r"\.handle_inode_event\s*=\s*ksu_handle_inode_event",
     ".handle_event = ksu_handle_inode_event",
     "ops 表字段名"),
    # --- 2) seccomp: 本树 `struct seccomp = { int mode; struct seccomp_filter *filter; }`
    #          没有 filter_count(计数属于 filter 对象本身，这里既不该读也不该清)；
    #          紧邻的两行已经把 mode/filter 清干净 ⇒ 这一行注释掉。
    ("policy/app_profile.c",
     r"[ \t]*atomic_set\(&current->seccomp\.filter_count, 0\);",
     "/* 5.4 没有 seccomp.filter_count(mode/filter 已在上面清零) —— 见 kmod/ROUTE-B-OFFSET-INVERSION.md §6.5 */",
     "删 filter_count 清零"),
]

for rel, pat, rep, label in EDITS:
    p = os.path.join(KSU, rel)
    s = open(p, encoding="utf-8", errors="replace").read()
    if rep in s:
        print("跳过(已打过) %-26s %s" % (rel, label))
        continue
    n = len(re.findall(pat, s))
    if n != 1:
        print("!! %-26s %s: 锚点命中 %d 次(要求 1) ⇒ 不动这个" % (rel, label, n))
        continue
    s = re.sub(pat, rep, s, count=1)
    print("已改 %-28s %s" % (rel, label))
    if not DRY:
        open(p, "w", encoding="utf-8", newline="\n").write(s)
