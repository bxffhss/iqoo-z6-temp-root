#!/usr/bin/env bash
# remote_permcheck2.sh —— 只读第二格：把 dispatch 的动词权限表与 is_manager() 的定义读全，
#   以及确认 O_CLOEXEC 对"装进 zygote ⇒ 之后 fork 出的 app 继承"这条路到底有没有影响。
set -u
F=/root/k/ksu/kernel/supercall/dispatch.c
S=/root/k/ksu/kernel/supercall/supercall.c
echo "=== 1) 动词表(名字 = perm_check)：整段抄回来 ==="
sed -n '700,860p' "$F" 2>/dev/null | grep -anE '\[KSU_CMD|\.perm_check|\.cmd|allowed_for_su|always_allow|only_root|only_manager|manager_or_root' | head -60
echo
echo "=== 2) 这四个检查函数各自到底查什么 ==="
grep -anA12 'static bool only_root\|static bool only_manager\|static bool manager_or_root\|static bool always_allow\|static bool allowed_for_su' "$F" 2>/dev/null | head -60
echo
echo "=== 3) is_manager() 与 su_mgr uid 的来源 ==="
grep -rnA8 'bool is_manager(void)' /root/k/ksu/kernel 2>/dev/null | head -24
echo
echo "=== 4) ioctl 入口：fd 的 private_data/permissions 是怎么参与判定的 ==="
grep -anB3 -A22 'static long .*ioctl\|ksu_ioctl\|unlocked_ioctl' "$F" 2>/dev/null | head -50
echo
echo "=== 5) CLOEXEC 相关：谁设 permissions，install 之后 fd_flags 传了什么 ==="
grep -anB2 -A10 'ksu_install_fd_with_permissions\|int ksu_install_fd(void)\|int ksu_install_su_fd' "$S" 2>/dev/null | head -46
echo "PERMCHK2_DONE"
