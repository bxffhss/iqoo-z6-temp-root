#!/bin/bash
# 取"剩下 6 类错误"的代码现场 + flask.h 的真实下落。改源码必须先看现场，不许猜。
LOG=/home/lucy/ksu_sites.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel

echo "=== flask.h 在哪(全树找) ==="
find "$KDIR" -name 'flask.h' 2>/dev/null | head -5
find /root/k/ksu -name 'flask.h' 2>/dev/null | head -5
echo "--- KDIR 里有 security/selinux 吗:"; ls -d "$KDIR/security/selinux" 2>&1; ls "$KDIR/security/selinux/include" 2>/dev/null | head
echo "--- KSU 里谁 include 了 selinux 私有头:"
grep -rn 'security/selinux' "$M" | head -8

echo; echo "=== 1) TWA_RESUME 两处现场 ==="
sed -n '125,140p' "$M/supercall/supercall.c"
echo "---"
sed -n '462,478p' "$M/policy/allowlist.c"

echo; echo "=== 2) seccomp filter_count 现场 ==="
sed -n '94,116p' "$M/policy/app_profile.c"

echo; echo "=== 3) fsnotify(pkg_observer)现场: ops 表 + 处理函数签名 ==="
sed -n '1,70p' "$M/manager/pkg_observer.c" | grep -n -A18 'fsnotify_ops'

echo; echo "=== 4) patch_memory.c 的 __p4d_to_phys 与 copy_to_kernel_nofault 现场 ==="
sed -n '28,60p' "$M/hook/arm64/patch_memory.c"
echo "---"
sed -n '132,160p' "$M/hook/arm64/patch_memory.c"
echo "END $(date)"
