#!/usr/bin/env bash
set -u
T=/root/k/linux-5.4.281
echo "=== A) get_unused_fd_flags 的真实实现与它对 current->files 的假设 ==="
grep -rn 'define get_unused_fd_flags\|get_unused_fd_flags(' $T/include/linux/ FDfile 2>/dev/null | head -5
grep -n -A16 'int __get_unused_fd_flags' $T/fs/file.c | head -26
grep -n -B3 -A22 'alloc_fd\|__get_unused_fd_flags' $T/fs/file.c | sed -n '1,60p'
echo
echo "=== B) task_work_add 函数体全文(它在 PF_EXITING 时返回什么) ==="
awk '/^int task_work_add/,/^}/' $T/kernel/task_work.c | head -40
echo "---- 顺带:task_work_run 的调用点(证明 do_exit 收尾会跑我们排队的活)"
grep -rn 'exit_task_work\|task_work_run()' $T/kernel/exit.c $T/kernel/task_work.c | head -8
echo
echo "=== C) 我们的回调在 files==NULL 时会不会被 ksu_install_fd 之外的东西挡住 ==="
grep -n -B2 -A18 'static void ksu_fd_install_tw_func' $T/../k/ksu/kernel/infra/dev_syms.c | head -26
echo "FDINSTALL_AUDIT3_DONE"
