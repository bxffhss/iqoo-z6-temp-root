#!/usr/bin/env bash
set -u
echo "=== 1) ksu_install_fd() 的定义在哪、本体全文 ==="
DEF=$(grep -rln 'int ksu_install_fd(void)' /root/k/ksu 2>/dev/null | grep -v dev_syms | head -1)
echo "定义文件=[$DEF]"
[ -n "$DEF" ] && grep -n -A40 'int ksu_install_fd(void)' "$DEF" | head -60
echo
echo "=== 2) 它往下调的那层(with_permissions/anon_inode)全文 ==="
grep -rn -A34 'static int ksu_install_fd_with_permissions\|int ksu_install_fd_with_permissions' /root/k/ksu 2>/dev/null | head -50
echo
echo "=== 3) get_unused_fd_flags/__get_unused_fd_flags 对 current->files 的假设 ==="
grep -n -A14 'int __get_unused_fd_flags' /root/k/linux-5.4.281/fs/file.c | head -24
echo
echo "=== 4) task_work_add 本体：PF_EXITING 到底拒不拒 ==="
sed -n '1,80p' /root/k/linux-5.4.281/kernel/task_work.c | grep -n -A24 'int task_work_add'
echo
echo "=== 5) 驱动 fd 的 fops 有没有 .owner=THIS_MODULE ==="
grep -rn -B2 -A10 '\.owner\s*=\s*THIS_MODULE' /root/k/ksu/kernel/supercall/supercall.c 2>/dev/null | head -24
grep -rn 'anonymous_inode_fops\|ksu_fd_fops\|static const struct file_operations' /root/k/ksu/kernel 2>/dev/null | head -10
echo "FDINSTALL_AUDIT2_DONE"
