#!/usr/bin/env bash
set -u
T=/root/k/linux-5.4.281
echo "=== 1) get_unused_fd_flags / __get_unused_fd_flags 全文 ==="
grep -n -B4 -A14 '^int get_unused_fd_flags' $T/fs/file.c
grep -n -B2 -A22 '__get_unused_fd_flags(unsigned' $T/fs/file.c $T/fs/open.c 2>/dev/null | head -40
echo "=== 2) alloc_fd 头几行(看它怎么取 files、有没有 !files 分支) ==="
awk '/^static int alloc_fd\(/,/^}/' $T/fs/file.c | head -30
grep -rn -A26 'static int alloc_fd' $T/fs/file.c | sed -n '1,34p'
echo "=== 3) task_work_add 全文 ==="
sed -n '40,105p' $T/kernel/task_work.c
echo "=== 4) 我们的回调(修正路径) ==="
grep -n -B2 -A10 'static void ksu_fd_install_tw_func' /root/k/ksu/kernel/infra/dev_syms.c
echo "FDINSTALL_AUDIT4_DONE"
