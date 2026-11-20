#!/bin/bash
K=/root/k/ksu/kernel
echo '=== A) profile_to_cred 的本体 ==='
grep -rn "profile_to_cred" "$K/policy/allowlist.c" | head -5
awk '/static void profile_to_cred/,/^}/' "$K/policy/allowlist.c"
echo '=== B) 第 428 行 override_creds 所在函数(往上看 30 行) ==='
sed -n '400,452p' "$K/policy/allowlist.c"
echo '=== C) 这个函数被谁调(全树引用) ==='
grep -rn "ksu_give_root_creds\|become_root\|allow_creds\|ksu_root_task" "$K" --include=*.c | head -10
echo END
