#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rc54：让 sucompat 战线**能被二分**（md §6.104）。

第一百零三发 ATT=3(完整 sucompat)一手：脚印停在
    X5 before setup_groups / X6 before setup_selinux: domain=u:r:ksu:s0 / X7 before commit_creds: uid=0 …
之后再没有 X8 ⇒ 看起来死在 `commit_creds()` 里。但这条日志**不能单独定案**：
`KSUBEAT F sys_enter` 那一格原本"每一次 execve/execveat 都印"(整机每秒几十次)，环形缓冲被我们
自己的洪印刷爆，而活落盘是 `dd bs=512 count=1` 逐块搬 ⇒ 会**整段丢回执**，丢的恰好可能是 X8/X9。
（同一条教训在 §6.94 记过：活落盘落后死点 0.5 秒以上。）

⇒ 本脚本做两件事：
  ① 收紧洪印：新参数 `ksu_trace_print`(默认 1=只在"真要改道的那一刻"印，即 execve/execveat 且挂了钩子；
     2=恢复老行为；0=连开火回执都不印)。回执密度降下来，死点前后才读得准。
  ② 给 `commit_creds` 之后那两笔各自一个开关，一发只关一笔地二分：
     `ksu_no_disable_seccomp`（`disable_seccomp()` 在 seccomp_cache.c 里要动 filter/发引用，
     历史上 §6.63 那种"改执行中任务的状态"翻过车）、
     `ksu_no_mark_threads`（`for_each_thread` 给全部线程写 tracepoint 标志位）。
用法：python3 patch_ksu_sucompat_gates2.py <KSU 源码根>     # 幂等
"""
import io
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"
HM = M + "/hook/syscall_hook_manager.c"
AP = M + "/policy/app_profile.c"

# ---------- ① 收紧 KSUBEAT F 的洪印 ----------
A_OLD = """        int nfired = atomic_inc_return(&ksu_tp_fired);
        if (nfired <= 8 || id == __NR_execve || id == __NR_execveat)
"""
A_NEW = """        int nfired = atomic_inc_return(&ksu_tp_fired);
        /* rc54(md §6.104)：老口径"每次 execve/execveat 都印"在本机是每秒几十行的洪印，
         * 会把环形缓冲刷爆 ⇒ 活落盘(dd 逐块)整段丢回执，而我判死因靠的就是这些回执。
         * 默认(1)只在"真的要改道的那一刻"印：execve/execveat 且这个号挂了钩子。 */
        int want = 0;
        if (ksu_trace_print == 2)
            want = (nfired <= 8 || id == __NR_execve || id == __NR_execveat);
        else if (ksu_trace_print == 1)
            want = ksu_has_syscall_hook(id);
        else
            want = (nfired <= 4);
        if (want)
"""
A_PARAM = """/* rc54(md §6.104)：KSUBEAT F 回执的密度开关。1=只在改道在即印(默认)，2=老行为(每次 execve 都印)，
 * 0=只在头四次开火时印。判死因要靠这些回执，洪印会把它们从活落盘里挤掉。 */
int ksu_trace_print __read_mostly = 1;
module_param(ksu_trace_print, int, 0444);
MODULE_PARM_DESC(ksu_trace_print, "KSUBEAT F 回执密度: 0=四次开火, 1=只在改道在即, 2=每次 execve/execveat");

"""
A_ANCHOR = "#ifdef CONFIG_HAVE_SYSCALL_TRACEPOINTS\nstatic atomic_t ksu_tp_fired = ATOMIC_INIT(0);\n"

# ---------- ② commit_creds 之后两笔各一个开关 ----------
B_OLD = """    disable_seccomp();
    pr_info("KSUBEAT X9 disable_seccomp done\\n");
"""
B_NEW = """    if (ksu_no_disable_seccomp) {
        pr_info("KSUBEAT X9s 跳过 disable_seccomp(ksu_no_disable_seccomp=1)\\n");
    } else {
        disable_seccomp();
        pr_info("KSUBEAT X9 disable_seccomp done\\n");
    }
"""
C_OLD = """    for_each_thread (p, t) {
        ksu_set_task_tracepoint_flag(t);
    }
    pr_info("KSUBEAT XA threads marked: pid=%d\\n", p->pid);
"""
C_NEW = """    if (ksu_no_mark_threads) {
        pr_info("KSUBEAT XAs 跳过线程打标(ksu_no_mark_threads=1)\\n");
    } else {
        for_each_thread (p, t) {
            ksu_set_task_tracepoint_flag(t);
        }
        pr_info("KSUBEAT XA threads marked: pid=%d\\n", p->pid);
    }
"""
B_PARAM = """/* rc52/rc54(md §6.100/§6.104)：escape 成功之后这三笔都**不止改当前任务**，
 * 每笔单独一个开关，一发只关一笔地二分：
 *   ksu_no_disable_seccomp  = 不动 seccomp(seccomp_cache.c 里要摘 filter/放引用)
 *   ksu_no_mark_threads     = 不遍历线程写 tracepoint 标志位
 * 默认 0=照旧全做。 */
bool ksu_no_disable_seccomp __read_mostly = false;
module_param(ksu_no_disable_seccomp, bool, 0444);
MODULE_PARM_DESC(ksu_no_disable_seccomp, "escape: 跳过 disable_seccomp()");
bool ksu_no_mark_threads __read_mostly = false;
module_param(ksu_no_mark_threads, bool, 0444);
MODULE_PARM_DESC(ksu_no_mark_threads, "escape: 跳过 for_each_thread 打 tracepoint 标");

"""
B_ANCHOR = "int escape_with_root_profile(void)\n"


def sub_once(path, old, new, tag):
    s = io.open(path, encoding="utf-8").read()
    if s.count(old) != 1:
        print("!! %s 的锚点命中 %d 次(要正好 1 次) ⇒ %s 不改" % (path.split("/")[-1], s.count(old), tag))
        return False
    io.open(path, "w", encoding="utf-8", newline="\n").write(s.replace(old, new, 1))
    print("  ok %s: %s" % (path.split("/")[-1], tag))
    return True


def main():
    ok = True
    hm = io.open(HM, encoding="utf-8").read()
    if "ksu_trace_print" in hm:
        print("  syscall_hook_manager.c 已收紧(跳过)")
    else:
        ok &= sub_once(HM, A_OLD, A_NEW, "KSUBEAT F 只在改道在即印")
        ok &= sub_once(HM, A_ANCHOR, A_ANCHOR + A_PARAM, "参数 ksu_trace_print")
    ap = io.open(AP, encoding="utf-8").read()
    if "ksu_no_disable_seccomp" in ap:
        print("  app_profile.c 已加开关(跳过)")
    else:
        ok &= sub_once(AP, B_OLD, B_NEW, "disable_seccomp 可关")
        ok &= sub_once(AP, C_OLD, C_NEW, "线程打标可关")
        ok &= sub_once(AP, B_ANCHOR, B_PARAM + B_ANCHOR, "两个参数定义")
    if not ok:
        return 1
    for f, ks in ((AP, ("X9s", "XAs", "ksu_no_disable_seccomp", "ksu_no_mark_threads")),
                  (HM, ("ksu_trace_print",))):
        s = io.open(f, encoding="utf-8").read()
        print("  校验 %s: %s" % (f.split("/")[-1],
              " ".join("%s=%d" % (k, s.count(k)) for k in ks)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
