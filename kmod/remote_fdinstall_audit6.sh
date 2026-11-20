#!/usr/bin/env bash
set -u
T=/root/k/linux-5.4.281
echo "=== 1) task_work_add 函数体全文(加入那一刻到底拒不拒 PF_EXITING) ==="
awk '/^int task_work_add/,/^}/' $T/kernel/task_work.c
echo "=== 2) 带行号的同一段(只锚 task_work_add 起讫行) ==="
grep -n 'task_work_add\|PF_EXITING\|work_exited\|set_notify_resume\|-ESRCH' $T/kernel/task_work.c
echo "=== 3) do_exit 里 exit_files(:855) 与 exit_task_work(:860) 的上下文 ==="
sed -n '845,865p' $T/kernel/exit.c
echo "=== 4) 对照：内核自己在这条路上有没有别的地方挡 NULL files ==="
grep -n 'current->files' $T/fs/file.c | head -12
echo "FDINSTALL_AUDIT6_DONE"
