#!/usr/bin/env bash
# remote_permcheck.sh —— 远端只读一格：驱动 fd 到手后，非 Manager 的调用者到底能不能做特权动词？
#   为什么要读实：本打算把 fd 常备进 zygote(=> 之后每个 app 都继承得到它)，
#   而 rc36 那句"fd 到手后每个 ioctl 仍受内核 perm_check 约束"只是**注释**，本地那份 dispatch 里
#   我只看到 is_manager() 用来打 flag，没看到闸门 ⇒ 不能靠注释决定放不放宽暴露面。
#   全程只读(find/grep)，不编译、不写树。
set -u
echo "=== 0) 找 KSU 树 ==="
for d in /root/k /root/k/*; do [ -d "$d" ] || continue; ls -d "$d" 2>/dev/null; done | head -20
echo
echo "=== 1) 关键源文件在哪 ==="
FILES=$(find /root/k -maxdepth 6 -type f \( -name 'allowlist.c' -o -name 'supercall.c' -o -name 'dispatch.c' -o -name 'kernel_umount.c' -o -name 'init.c' \) 2>/dev/null | grep -aE 'ksu|KernelSU|kernel' | head -20)
echo "$FILES"
echo
echo "=== 2) 闸门证据：谁在 ioctl 入口检查调用者 ==="
for f in $FILES; do
    echo "--- $f"
    grep -anE 'has_permission|perm_check|is_manager\(|KSU_ROOT_UID|capable\(|in_group_p|AID_SHELL|uid_a\(\)|-EACCES|-EPERM' "$f" 2>/dev/null | head -18
done
echo
echo "=== 3) 特权动词的清单(SET_APP_PROFILE/GRANT/REVOKE/DEL 之类)与其检查行 ==="
for f in $FILES; do
    echo "--- $f"
    grep -anB2 -A6 'KSU_CMD_SET_APP_PROFILE\|KSU_CMD_DEL_ALLOW_LIST\|KSU_CMD_GRANT_ROOT\|handle_app_profile\|handle_set_app_profile' "$f" 2>/dev/null | head -40
done
echo
echo "=== 4) ksu_install_fd 的实现(看它给的是不是无 CLOEXEC 的匿名 fd) ==="
for f in $(find /root/k -maxdepth 6 -type f -name 'supercall.c' 2>/dev/null | head -3); do
    echo "--- $f"
    grep -anA14 'int ksu_install_fd' "$f" 2>/dev/null | head -22
done
echo "PERMCHK_DONE"
