#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rc23：给 `escape_with_root_profile()` 内部装一条 **X0..X9 阶梯打印**（md §6.43）。

第十九发已经证明：sysfs 参数目录在本机不存在 ⇒ v12 的"运行时改闸门"其实一次都没生效，
那一发跑的就是**全开路径**（`escape_with_root_profile()` 真执行了），然后 0.3~1.5s 内整机没了。
而 `KSUBEAT SU0..SU4` 只把"进 su 分支"与"escape 返回之后"分开，**escape 函数内部是一个黑盒**：
  prepare_creds / ksu_get_root_profile / alloc_uid+free_uid / caps / setup_groups /
  setup_selinux / commit_creds / disable_seccomp(那个 memcpy(fake,current) + 我们的
  seccomp_filter_release 空桩) / for_each_thread 打标 / setup_mount_ns
⇒ 这一发之前先把黑盒切成 10 段，配合 v13 的 0.2s 活落盘 = **一扇窗口就能指认是哪一步**。

★全部是 pr_info，没有任何行为改动；`profile` 的 uid/gid/groups_count/域串一并印出来，
  好判"名单 seed 的字段是不是垃圾"（`groups_count` 是 mkallow 没显式写的那一项）。
幂等 tag：KSUBEAT X0..X9。
"""
import io
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"
F = M + "/policy/app_profile.c"

EDITS = [
    ("X0X1",
     '    cred = prepare_creds();\n'
     '    if (!cred) {\n'
     '        pr_warn("prepare_creds failed!\\n");\n'
     '        return -ENOMEM;\n'
     '    }\n',
     '    pr_info("KSUBEAT X0 escape enter: pid=%d uid=%u euid=%u comm=%s\\n",\n'
     '            current->pid, current_uid().val, current_euid().val, current->comm);\n'
     '    cred = prepare_creds();\n'
     '    if (!cred) {\n'
     '        pr_warn("prepare_creds failed!\\n");\n'
     '        return -ENOMEM;\n'
     '    }\n'
     '    pr_info("KSUBEAT X1 prepare_creds ok: cred=%px euid=%u\\n", cred, cred->euid.val);\n'),

    ("X2",
     '    profile = ksu_get_root_profile(cred->uid.val);\n',
     '    profile = ksu_get_root_profile(cred->uid.val);\n'
     '    pr_info("KSUBEAT X2 profile: p=%px want_uid=%u prof_uid=%u gid=%u groups_count=%u domain=%s\\n",\n'
     '            profile, cred->uid.val, profile ? profile->uid : 0xFFFF,\n'
     '            profile ? profile->gid : 0xFFFF,\n'
     '            profile ? profile->groups_count : 0,\n'
     '            profile ? profile->selinux_domain : "(null)");\n'
     '    if (!profile) {\n'
     '        pr_err("KSUBEAT X2e profile=NULL, 放弃 escape\\n");\n'
     '        abort_creds(cred);\n'
     '        return -EINVAL;\n'
     '    }\n'),

    ("X3",
     '    new_user = alloc_uid(cred->uid);\n'
     '    if (!new_user) {\n'
     '        ret = -ENOMEM;\n'
     '        goto out_abort_creds;\n'
     '    }\n',
     '    pr_info("KSUBEAT X3 before alloc_uid: uid=%u old_user=%px\\n", cred->uid.val, cred->user);\n'
     '    new_user = alloc_uid(cred->uid);\n'
     '    if (!new_user) {\n'
     '        pr_err("KSUBEAT X3e alloc_uid 返回 NULL(解析层没解析成功就是这形状)\\n");\n'
     '        ret = -ENOMEM;\n'
     '        goto out_abort_creds;\n'
     '    }\n'
     '    pr_info("KSUBEAT X4 alloc_uid ok: new_user=%px\\n", new_user);\n'),

    ("X5",
     '    setup_groups(profile, cred);\n'
     '    setup_selinux(profile->selinux_domain, cred);\n'
     '\n'
     '    commit_creds(cred);\n'
     '\n'
     '    disable_seccomp();\n',
     '    pr_info("KSUBEAT X5 before setup_groups\\n");\n'
     '    setup_groups(profile, cred);\n'
     '    pr_info("KSUBEAT X6 before setup_selinux: domain=%s\\n", profile->selinux_domain);\n'
     '    setup_selinux(profile->selinux_domain, cred);\n'
     '    pr_info("KSUBEAT X7 before commit_creds: uid=%u euid=%u cap0=%#x\\n",\n'
     '            cred->uid.val, cred->euid.val, cred->cap_effective.cap[0]);\n'
     '    commit_creds(cred);\n'
     '    pr_info("KSUBEAT X8 commit_creds done: now uid=%u euid=%u\\n", current_uid().val,\n'
     '            current_euid().val);\n'
     '    disable_seccomp();\n'
     '    pr_info("KSUBEAT X9 disable_seccomp done\\n");\n'),

    ("XA",
     '    for_each_thread (p, t) {\n'
     '        ksu_set_task_tracepoint_flag(t);\n'
     '    }\n',
     '    for_each_thread (p, t) {\n'
     '        ksu_set_task_tracepoint_flag(t);\n'
     '    }\n'
     '    pr_info("KSUBEAT XA threads marked: pid=%d\\n", p->pid);\n'),

    ("XB",
     '    setup_mount_ns(profile->namespaces);\n',
     '    pr_info("KSUBEAT XB before setup_mount_ns: ns=%d\\n", profile->namespaces);\n'
     '    setup_mount_ns(profile->namespaces);\n'
     '    pr_info("KSUBEAT XC setup_mount_ns done, escape 全部跑完\\n");\n'),
]

s = io.open(F, encoding="utf-8", errors="replace").read()
n = 0
for tag, old, new in EDITS:
    probe = "KSUBEAT X" + {"X0X1": "0", "X2": "2", "X3": "3", "X5": "5", "XA": "A", "XB": "B"}[tag]
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
