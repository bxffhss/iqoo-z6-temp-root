#!/usr/bin/env bash
# remote_fdinstall_audit.sh —— 只读：核“task_work 里往目标进程装 fd”这条路的三个生死前提(我们那棵 5.4 树)。
set -u
K=/root/k/ksu
echo "=== 0) 树在哪、版本 ==="
grep -an '^VERSION\|^PATCHLEVEL\|^SUBLEVEL' /root/k/linux-5.4.281/Makefile 2>/dev/null | head -3
ls -d /root/k/linux-5.4.281 2>/dev/null || ls /root/k | head
echo
echo "=== 1) do_exit 里 exit_files / exit_fs / exit_mm / exit_task_work 的**先后** ==="
for F in /root/k/linux-5.4.281/kernel/exit.c /root/k/kernel/exit.c; do
  [ -f "$F" ] || continue
  echo "--- $F"
  grep -an 'exit_files(tsk)\|exit_fs(tsk)\|exit_mm(tsk)\|exit_task_work(tsk)\|EXIT_TRACE\|do_exit' "$F" | sed -n '1,40p'
done
echo
echo "=== 2) task_work_add：目标正在退出时到底拒不拒(PF_EXITING 分支) ==="
for F in /root/k/linux-5.4.281/kernel/task_work.c /root/k/kernel/task_work.c; do
  [ -f "$F" ] || continue
  echo "--- $F"; grep -an -A26 'int task_work_add' "$F" | head -40
done
echo "=== 2b) 原型第三参名字(是 add_last 还是 head?) ==="
grep -an -B4 -A8 'int task_work_add' /root/k/linux-5.4.281/include/linux/task_work.h 2>/dev/null | head -24
echo
echo "=== 3) exit_files 有没有把 tsk->files 置 NULL ==="
for F in /root/k/linux-5.4.281/fs/file.c /root/k/fs/file.c; do
  [ -f "$F" ] || continue
  echo "--- $F"; grep -an -A14 'void exit_files(struct task_struct \*tsk)' "$F" | head -22
  echo "  ---- __fd_install / fd_install 对 current->files 的假设"
  grep -an -A16 'void __fd_install\|int fd_install' "$F" | head -40
done
echo
echo "=== 4) 我们的 ksu_install_fd() 本体：有没有 !current->files 的护、拿的是不是 THIS_MODULE 的 fops ==="
grep -rn -A34 'int ksu_install_fd(void)' "$K" 2>/dev/null | head -60
echo "---- 它调用的那个 with_permissions 版本"
grep -rn -A30 'ksu_install_fd_with_permissions' "$K" 2>/dev/null | head -50
echo
echo "=== 5) 顺带：anon_inode 那条路的 fops 有没有 .owner=THIS_MODULE(决定 rmmod 会不会把 fd 抽走) ==="
grep -rn -B4 -A12 'static const struct file_operations .*driver_fops\|ksu_driver_fops\|anon_inode_getfile\|anon_inode_getfd' "$K" 2>/dev/null | head -40
echo "FDINSTALL_AUDIT_DONE"
