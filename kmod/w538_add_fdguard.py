#!/usr/bin/env python3
# w538_add_fdguard.py —— 把 §6.394 那条护栏打进**树上真正编 rc67 的那份 dev_syms.c**
#   (基线＝从构建机 pull 下来的 /home/lucy/ksu_dev_syms.c，md5 5b8d86358419d9429c2c290964b08a60)。
#   为什么要有这个生成器而不是手改仓库那份：仓库里的 kmod/ksu_dev_syms.c 比树上的多 49 行**已废弃的 rc64
#   mgrdomain 草稿**(真实现后来搬进 policy/allowlist.c，由 patch_ksu_mgrdomain.py 打)⇒ 拿它当基线就至少多出
#   两处非单变量。所以：基线只能取自构建机，改动只允许这一处，且由本脚本自己复证。
#   用法：python kmod/w538_add_fdguard.py <基线.c> <输出.c>
#   四道自审：①锚点恰好 1 次(否则停)；②NULLFILES 那串在；③旧裸调形状不再出现、新形状恰好 1 次；④护栏 1 份。
import io
import sys

ANCHOR = ("\tstruct ksu_fd_install_tw *tw = container_of(cb, struct ksu_fd_install_tw, cb);\n"
          "\tint nfd = ksu_install_fd();\n")

GUARD = """\tstruct ksu_fd_install_tw *tw = container_of(cb, struct ksu_fd_install_tw, cb);
\tint nfd;

\t/* §6.394（10-22 22:4x）：这个回调可能是在**目标自己的 do_exit 收尾**里跑的——
\t *   kernel/exit.c 的 exit_files(tsk)(:855，它把 tsk->files = NULL，fs/file.c:443) 早于
\t *   exit_task_work(tsk)(:860)；而 ksu_install_fd() → get_unused_fd_flags()(fs/file.c:545) →
\t *   __alloc_fd()(fs/file.c:480) 第一行就 spin_lock(&files->file_lock)，**整条链没有 !files 防护**
\t *   ⇒ 对着 NULL 加锁＝踩空指针。task_work_add()(kernel/task_work.c:28) 只拒"排队那一刻已是
\t *   work_exited"的目标(-ESRCH)，"排队时活着、随后退出"这一路拒不掉；而写 /proc/ksu_install_fd 的
\t *   pid 是用户态挑的（实测：pidof zygote64 在这台机会返回 zygote 刚 fork、还没改名的瞬时子进程）。
\t *   顺带挡住另一个形状：目标根本没有 fd 表的内核线程（触发口收任何 pid）。 */
\tif (unlikely(!current->files)) {
\t\tpr_err("KSUFDINST NULLFILES skip pid=%d comm=[%s]: target has no files (->files==NULL: exiting, or a kthread); installing would deref NULL\\n",
\t\t       tw->pid, current->comm);
\t\tkfree(tw);
\t\treturn;
\t}
\tnfd = ksu_install_fd();
"""


def main():
    src, dst = sys.argv[1], sys.argv[2]
    s = io.open(src, encoding="utf-8", newline="").read()
    n = s.count(ANCHOR)
    if n != 1:
        print("[x] 锚点出现 %d 次(必须恰好 1) ⇒ 停手，别把旧形状留在别处" % n)
        return 1
    out = s.replace(ANCHOR, GUARD)
    io.open(dst, "w", encoding="utf-8", newline="").write(out)
    ok1 = "KSUFDINST NULLFILES skip" in out
    ok2 = out.count("int nfd = ksu_install_fd();") == 0
    ok3 = out.count("\tnfd = ksu_install_fd();") == 1
    ok4 = out.count("if (unlikely(!current->files)) {") == 1
    print("  打完：行数 %d → %d(多 %d)  NULLFILES串在=%d 旧裸调已清=%d 新调恰1=%d 护栏恰1=%d  ※四个数都是'条件成立=1'，不是次数"
          % (s.count("\n"), out.count("\n"), out.count("\n") - s.count("\n"),
             ok1, ok2, ok3, ok4))
    if not (ok1 and ok2 and ok3 and ok4):
        print("[x] 红灯：打完之后的形状不对")
        return 1
    print("PASS 基线+单护栏已生成(唯一改动＝ksu_fd_install_tw_func 开头那道 !current->files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
