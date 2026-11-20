#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rc20 诊断+安全补丁（md §6.39）。

第十七发(rc19, stage=7, mass_mark=0)读回的整份 dmesg 给了两条硬事实：
  ① `patch syscall 42, 0x..eab88e9c -> 0x..c5eab0bc` 紧跟 `patch syscall 42 failed`
     ⇒ **sys_call_table 那笔写从来没落地过**，调度器根本不可达；
     (顺带解释了悬着的"KSUBEAT A readback 为什么不印"——它在失败 return 之后，不是丢了。)
  ② tracepoint 注册成功、控制面全绿、fd 装得上 ⇒ 除①之外都通了。
失败的 errno 被 KSU 原代码吞了(`return -EIO`)，所以这一发的目标是
**把"写为什么失败"和"写到底落没落地"变成两行能证伪的打印**。

同时补三条安全闸(都是第十六发那次"adb 全 ENOSYS"这类自伤的直接解药)：
  A. 调度器 E3 分支不再 `return -ENOSYS`，改成**回落原实现** ⇒ 就算改道/存档出问题，
     最坏也只是"这一个 syscall 白跑一趟"，不会把 marked 进程(尤其 adbd/zygote)打死。
  B. `ksu_mark_running_process_locked()` 也吃 `ksu_mass_mark` 闸门 ⇒ `mass_mark=0` 时
     **一个存量进程都不会被打标**，实验面缩到"我们自己显式 mark 的 pid"。
  C. 打印 `patch syscall` 的真实 rc。

幂等：每处都靠自己的 tag(P1/F/F2/G/RUNNING-MASSGATE/E3FALLBACK/PATCHRC)判重。
"""
import io
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"

JOBS = [
    # ---------------- 1) patch_memory.c：写前比对 + 逐步回执 ----------------
    (M + "/hook/arm64/patch_memory.c",
     [
         ("P1",
          '    void *map = set_fixmap_offset(FIX_TEXT_POKE0, phy);\n'
          '    pr_debug("fixmap addr for patch 0x%lx: 0x%lx\\n", p, (unsigned long)map);\n'
          '\n'
          '    ret = (int)copy_to_kernel_nofault(map, src, len);\n'
          '\n'
          '    clear_fixmap(FIX_TEXT_POKE0);\n',
          '    void *map = set_fixmap_offset(FIX_TEXT_POKE0, phy);\n'
          '    pr_info("KSUBEAT P1 patch: dst=%px phy=%#llx map=%px len=%zu\\n",\n'
          '            dst, (unsigned long long)phy, map, len);\n'
          '\n'
          '    /* ★★写前比对(正对照 + 安全闸)：fixmap 别名和原映射必须看到同一份内容。\n'
          '     * 若 phys_from_virt() 算错页，这里立刻看得见，而我们还没写任何东西 ⇒ 零破坏。\n'
          '     * 这一条同时回答"这笔写到底落没落地"，不再靠 ret=0。 */\n'
          '    if (len == sizeof(u64)) {\n'
          '        u64 cur_dst = *(u64 *)dst;\n'
          '        u64 cur_map = *(u64 *)map;\n'
          '        pr_info("KSUBEAT P2 aliascheck: map=%#llx dst=%#llx %s\\n",\n'
          '                (unsigned long long)cur_map, (unsigned long long)cur_dst,\n'
          '                cur_map == cur_dst ? "SAME(同一页)" : "DIFF(页算错，拒绝写)");\n'
          '        if (cur_map != cur_dst) {\n'
          '            clear_fixmap(FIX_TEXT_POKE0);\n'
          '            pr_err("KSUBEAT P3 abort: alias mismatch, 没有写任何东西\\n");\n'
          '            return -EIO;\n'
          '        }\n'
          '    }\n'
          '\n'
          '    ret = (int)copy_to_kernel_nofault(map, src, len);\n'
          '    pr_info("KSUBEAT P4 copy_to_kernel_nofault ret=%d\\n", ret);\n'
          '\n'
          '    clear_fixmap(FIX_TEXT_POKE0);\n'),
     ]),

    # ---------------- 2) syscall_hook.c：rc 落地 + 调度器不再打死进程 ----------------
    (M + "/hook/arm64/syscall_hook.c",
     [
         ("PATCHRC",
          '    if (ksu_patch_text(&ksu_syscall_table[nr], &fn, sizeof(fn), KSU_PATCH_TEXT_FLUSH_DCACHE)) {\n'
          '        pr_err("patch syscall %d failed\\n", nr);\n'
          '        return -EIO;\n'
          '    }\n',
          '    int patch_rc = ksu_patch_text(&ksu_syscall_table[nr], &fn, sizeof(fn), KSU_PATCH_TEXT_FLUSH_DCACHE);\n'
          '    if (patch_rc) {\n'
          '        pr_err("patch syscall %d failed rc=%d\\n", nr, patch_rc);\n'
          '        return patch_rc;\n'
          '    }\n'),
         ("E3FALLBACK",
          '    pr_info_ratelimited("KSUBEAT E3: orig_nr=%d 没挂 hook 或越界(hook=%px) pid=%d comm=%s\\n",\n'
          '            orig_nr, (void *)READ_ONCE(syscall_hooks[orig_nr >= 0 && orig_nr < __NR_syscalls ? orig_nr : 0]),\n'
          '            current->pid, current->comm);\n'
          '    return -ENOSYS;\n',
          '    /* ★原来是 `return -ENOSYS`：一条"没挂 hook 的号"被送进调度器就把那个系统调用打死。\n'
          '     * 第十六发 adbd 全局 `exec /system/bin/sh failed: Function not implemented` 就是这个形状。\n'
          '     * 改成回落原实现 ⇒ 最坏只是白跑一趟。 */\n'
          '    if (orig_nr >= 0 && orig_nr < __NR_syscalls && ksu_syscall_table) {\n'
          '        pr_info_ratelimited("KSUBEAT E3: orig_nr=%d 没挂 hook，回落原实现 pid=%d comm=%s\\n",\n'
          '                orig_nr, current->pid, current->comm);\n'
          '        return ksu_syscall_table[orig_nr](regs);\n'
          '    }\n'
          '    pr_info_ratelimited("KSUBEAT E4: orig_nr=%d 越界或 sys_call_table 没解析\\n", orig_nr);\n'
          '    return -ENOSYS;\n'),
     ]),

    # ---------------- 3) hook_manager：F=tracepoint 真的跑了吗 / F2=改道存档 ----------------
    (M + "/hook/syscall_hook_manager.c",
     [
         ("FDECL",
          '#ifdef CONFIG_HAVE_SYSCALL_TRACEPOINTS\n'
          '// sys_enter handler: redirect hooked syscalls to the dispatcher\n',
          '#ifdef CONFIG_HAVE_SYSCALL_TRACEPOINTS\n'
          'static atomic_t ksu_tp_fired = ATOMIC_INIT(0);\n'
          '// sys_enter handler: redirect hooked syscalls to the dispatcher\n'),
         ("F",
          '    if (ksu_dispatcher_nr < 0)\n'
          '        return;\n'
          '\n'
          '    if (ksu_has_syscall_hook(id)) {\n',
          '    if (ksu_dispatcher_nr < 0)\n'
          '        return;\n'
          '\n'
          '    {\n'
          '        int nfired = atomic_inc_return(&ksu_tp_fired);\n'
          '        if (nfired <= 8)\n'
          '            pr_info("KSUBEAT F sys_enter fired#%d: id=%ld dispatcher_nr=%d has_hook=%d "\n'
          '                    "pid=%d comm=%s ti_flags=%#lx\\n",\n'
          '                    nfired, id, ksu_dispatcher_nr, ksu_has_syscall_hook(id) ? 1 : 0,\n'
          '                    current->pid, current->comm, current_thread_info()->flags);\n'
          '    }\n'
          '\n'
          '    if (ksu_has_syscall_hook(id)) {\n'),
         ("F2",
          '#elif defined(__aarch64__)\n'
          '        PT_REGS_ORIG_SYSCALL(current_regs) = id;\n'
          '        current_regs->syscallno = ksu_dispatcher_nr;\n',
          '#elif defined(__aarch64__)\n'
          '        PT_REGS_ORIG_SYSCALL(current_regs) = id;\n'
          '        current_regs->syscallno = ksu_dispatcher_nr;\n'
          '        pr_info_ratelimited("KSUBEAT F2 redirect: id=%ld -> %d x8_stash=%#llx pid=%d\\n",\n'
          '                id, ksu_dispatcher_nr,\n'
          '                (unsigned long long)PT_REGS_ORIG_SYSCALL(current_regs), current->pid);\n'),
         ("F9",
          '    ksu_sys_enter_tp_unregister(ksu_sys_enter_handler);\n',
          '    pr_info("KSUBEAT F9 sys_enter fired total=%d\\n", atomic_read(&ksu_tp_fired));\n'
          '    ksu_sys_enter_tp_unregister(ksu_sys_enter_handler);\n'),
         ("ATOMICINC",
          '#include <linux/ptrace.h>\n',
          '#include <linux/ptrace.h>\n#include <linux/atomic.h>\n'),
     ]),

    # ---------------- 4) tp_marker：G=打标真的进了 ti->flags 吗 / 存量进程一律不打 ----------------
    (M + "/hook/tp_marker.c",
     [
         ("RUNNING-MASSGATE",
          'void ksu_mark_running_process_locked(void)\n'
          '{\n'
          '    struct task_struct *p, *t;\n'
          '    read_lock(&tasklist_lock);\n',
          'void ksu_mark_running_process_locked(void)\n'
          '{\n'
          '    struct task_struct *p, *t;\n'
          '    if (!ksu_mass_mark) {\n'
          '        pr_info("tp_marker: mark-running 被 ksu_mass_mark=0 拦掉(存量进程一个都不打标)\\n");\n'
          '        return;\n'
          '    }\n'
          '    read_lock(&tasklist_lock);\n'),
         ("G",
          '            ksu_set_task_tracepoint_flag(task);\n'
          '            pr_info("tp_marker: marked task pid=%d comm=%s\\n", pid, task->comm);\n',
          '            ksu_set_task_tracepoint_flag(task);\n'
          '            pr_info("tp_marker: marked task pid=%d comm=%s\\n", pid, task->comm);\n'
          '            pr_info("KSUBEAT G mark: pid=%d ti_flags=%#lx _TIF_SYSCALL_TRACEPOINT=%#lx "\n'
          '                    "在 _TIF_SYSCALL_WORK 里=%d\\n",\n'
          '                    pid, task_thread_info(task)->flags,\n'
          '                    (unsigned long)_TIF_SYSCALL_TRACEPOINT,\n'
          '                    !!(task_thread_info(task)->flags & _TIF_SYSCALL_WORK));\n'),
     ]),
]

total = 0
for path, edits in JOBS:
    try:
        s = io.open(path, encoding="utf-8", errors="replace").read()
    except IOError as e:
        print("!! 读不到 %s (%s)" % (path, e))
        continue
    n = 0
    for tag, old, new in edits:
        if tag in ("P1", "P2", "P3", "P4", "F", "F2", "F9", "G", "PATCHRC", "E3FALLBACK",
                   "RUNNING-MASSGATE", "ATOMICINC", "FDECL"):
            probe = {"P1": "KSUBEAT P1", "P2": "KSUBEAT P2", "P3": "KSUBEAT P3",
                     "P4": "KSUBEAT P4", "F": "KSUBEAT F sys_enter", "F2": "KSUBEAT F2",
                     "F9": "KSUBEAT F9", "G": "KSUBEAT G mark",
                     "PATCHRC": "patch_rc", "E3FALLBACK": "回落原实现",
                     "RUNNING-MASSGATE": "mark-running", "ATOMICINC": "linux/atomic.h",
                     "FDECL": "ksu_tp_fired"}[tag]
            if probe in s:
                print("  = 已有, 跳过 %s" % tag)
                continue
        c = s.count(old)
        if c != 1:
            print("  !! 锚点 %s 命中 %d 次, 不动" % (tag, c))
            continue
        s = s.replace(old, new, 1)
        n += 1
        print("  + %s (%s)" % (tag, path.split("/")[-1]))
    if n:
        io.open(path, "w", encoding="utf-8", newline="\n").write(s)
    total += n
    print("-- %s: 写了 %d 处" % (path.split("/")[-1], n))
print("总计 %d 处" % total)
