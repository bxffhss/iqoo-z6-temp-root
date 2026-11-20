#!/bin/bash
K=/root/k/ksu/kernel
F=$(grep -rl "profile_to_cred" "$K" --include=*.c | head -1)
echo "真实文件=[$F]"
[ -n "$F" ] && awk '/profile_to_cred/,/^}/' "$F" | head -45
echo '=== commit_creds/umh 在这份文件里有没有 ==='
[ -n "$F" ] && grep -n "commit_creds\|prepare_kernel_cred\|call_usermodehelper" "$F" | head -8
echo '=== klog.h 的 KSU_LOG 往哪写 ==='
sed -n '1,32p' "$K/klog.h"
echo END
