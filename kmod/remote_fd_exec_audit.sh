#!/usr/bin/env bash
set -u
# 只读审计：驱动 fd 到底在**哪些时刻**被装进进程 —— 决定"执法态 app 侧 su"那一格能不能排出来。
K=/root/k/ksu/kernel
echo "=== 1) ksu_install_fd() 的全部调用点(谁在什么时候装 fd) ==="
grep -rn "ksu_install_fd(" $K --include=*.c --include=*.h | grep -av "^.*int ksu_install_fd(void)$"
echo "=== 2) setuid_hook.c 第 37 行那处的上下文(它挂在什么事件上) ==="
sed -n '1,60p' $K/hook/setuid_hook.c
echo "=== 3) execve 那条路上有没有装 fd / 查名单的动作 ==="
grep -rn "allow_shell\|su_kernel_uids\|ksu_is_uid_approved\|is_uid_approved\|get_allow_list" $K/hook/*.c | head -18
echo "=== 4) 驱动 fd 的 O_CLOEXEC 在哪定的(supercall.c:86 附近) ==="
sed -n '45,95p' $K/supercall/supercall.c
echo "FD_EXEC_AUDIT_DONE"
