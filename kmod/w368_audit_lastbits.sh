#!/bin/bash
K=/root/k/ksu/kernel
echo '=== A) profile_to_cred 本体(非 Manager 那条才会走满) ==='
sed -n '/static bool profile_to_cred/,/^}/p' "$K/policy/selinux_util.c" | head -60
echo '=== B) 装载期会不会 commit cred(=当场改自己凭据) ==='
grep -n "commit_creds\|prepare_kernel_cred\|call_usermodehelper" "$K/policy/selinux_util.c" "$K/policy/allowlist.c" | head -10
echo '=== C) KSU_LOG 到底往哪儿写 ==='
sed -n '1,40p' "$K/klog.h"
echo END
