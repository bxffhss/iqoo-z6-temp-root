#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rc58：把 syscall 入口那几行回执**按号收紧**，别让 stat/faccessat 这种热路径把机器刷死（md §6.118）。

一手：`ksu_hook_mask=0x12`(execve+faccessat) 与 `0x1a`(+newfstatat) 两发，都在"授权 uid 的 app 一起来"
几毫秒内整机复位；死前 dmesg 里成对刷屏：
    KSUBEAT F sys_enter fired#…: id=79 …
    KSUBEAT F2 redirect: id=79 -> 42 x8_stash=0x4f …
    KSUBEAT BN dispatcher entered: syscallno=42 stash=79 …
根因是**我们自己**在 rc54 加的密度开关：`want = ksu_has_syscall_hook(id)` 是**按系统调用号**判断的，
不分 uid、也不分"是不是改道在即"。所以只要给 48/79 挂了钩，**全机每一次 faccessat/stat 都印一行**
(外加 F2/BN 两行)，app 启动阶段每秒几百次 ⇒ syscall 入口被 printk 拖死/看门狗复位。
`execve` 那一发从来不死，正因为一个进程只 exec 一次。

⇒ 三处收口：
  ① `F fired`：默认只印 execve/execveat/setresuid 这三个"我们真的关心改道"的号；
  ② `F2 redirect`：同样按号收口（stat/faccessat 的重定向不需要现场打印）；
  ③ `BN dispatcher entered`：改成 `pr_info_ratelimited`（调度器入口是所有钩子共用的，量最大的就是它）。
判据：`ksu_hook_mask=0x12` 下 app 起来**不死**，且 `@suprobe:` 印出 `access(...)=0`。
想退回旧口径：`ksu_trace_print=2`（老行为）/`=3`（本 rc 的默认，只是换了实现）。
用法：python3 patch_ksu_tracequiet.py <KSU 源码根>     # 幂等
"""
import io
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"
HM = M + "/hook/syscall_hook_manager.c"
SH = M + "/hook/arm64/syscall_hook.c"

# ---------- ① F fired 的 want 表达式 ----------
A_OLD = """        else if (ksu_trace_print == 1)
            want = ksu_has_syscall_hook(id);
"""
A_NEW = """        else if (ksu_trace_print == 1)
            want = ksu_has_syscall_hook(id);
        else if (ksu_trace_print == 3)
            /* rc58 默认：只印"改道在即"那三个号。stat/faccessat 挂了钩之后是全机每秒几百次的
             * 热路径，按号印会把 syscall 入口刷死(§6.118 的整机复位就是这么来的)。 */
            want = ksu_has_syscall_hook(id) &&
                   (id == __NR_execve || id == __NR_execveat || id == __NR_setresuid);
"""
# 默认值改成 3
D_OLD = "int ksu_trace_print __read_mostly = 1;"
D_NEW = "int ksu_trace_print __read_mostly = 3;   /* rc58：默认只印 execve 家族(见上面注释) */"

# ---------- ② F2 redirect ----------
B_OLD = """        pr_info("KSUBEAT F2 redirect: id=%ld -> %d x8_stash=%#llx pid=%d\\n",
                id, ksu_dispatcher_nr,
                (unsigned long long)PT_REGS_ORIG_SYSCALL(current_regs), current->pid);
"""
B_NEW = """        /* rc58(§6.118)：这条原来是"只要重定向就印" ⇒ 挂了 stat/faccessat 钩之后是全机热路径。
         * 按号收口：只有 execve 家族才印。 */
        if (id == __NR_execve || id == __NR_execveat)
            pr_info("KSUBEAT F2 redirect: id=%ld -> %d x8_stash=%#llx pid=%d\\n",
                    id, ksu_dispatcher_nr,
                    (unsigned long long)PT_REGS_ORIG_SYSCALL(current_regs), current->pid);
"""

# ---------- ③ BN dispatcher entered ----------
C_OLD = """    pr_info("KSUBEAT BN dispatcher entered: syscallno=%d stash=%d pid=%d comm=%s\\n",
            regs->syscallno, (int)PT_REGS_ORIG_SYSCALL(regs), current->pid, current->comm);
"""
C_NEW = """    /* rc58(§6.118)：调度器入口是所有钩子共用的，挂上 stat/faccessat 之后这里每秒几百次
     * ⇒ 必须限流(保留可查性，又不会把入口路径刷死)。 */
    pr_info_ratelimited("KSUBEAT BN dispatcher entered: syscallno=%d stash=%d pid=%d comm=%s\\n",
                        regs->syscallno, (int)PT_REGS_ORIG_SYSCALL(regs), current->pid,
                        current->comm);
"""


def sub(path, old, new, tag):
    s = io.open(path, encoding="utf-8").read()
    if new.split("(")[0].strip() and new in s:
        print("  已打过(跳过): %s" % tag)
        return True
    if s.count(old) != 1:
        print("!! %s 的锚点命中 %d 次(要正好 1) ⇒ 不改: %s" % (path.split("/")[-1], s.count(old), tag))
        return False
    io.open(path, "w", encoding="utf-8", newline="\n").write(s.replace(old, new, 1))
    print("  ok %s: %s" % (path.split("/")[-1], tag))
    return True


def main():
    ok = True
    ok &= sub(HM, A_OLD, A_NEW, "F fired 加 mode 3")
    ok &= sub(HM, D_OLD, D_NEW, "默认 ksu_trace_print=3")
    ok &= sub(HM, B_OLD, B_NEW, "F2 redirect 按号收口")
    ok &= sub(SH, C_OLD, C_NEW, "BN 入口改 ratelimited")
    if not ok:
        return 1
    for f, keys in ((HM, ("ksu_trace_print == 3", "id == __NR_execve || id == __NR_execveat")),
                    (SH, ("pr_info_ratelimited(\"KSUBEAT BN",))):
        s = io.open(f, encoding="utf-8").read()
        print("  校验 %s: %s" % (f.split("/")[-1], " ".join("%s=%d" % (k[:24], s.count(k)) for k in keys)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
