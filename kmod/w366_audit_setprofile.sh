#!/bin/bash
K=/root/k/ksu/kernel
echo '=== 1) ksu_set_app_profile 定义在哪 ==='
grep -rn "void ksu_set_app_profile\|bool ksu_set_app_profile\|ksu_set_app_profile(" "$K" --include=*.c --include=*.h | head -8
echo '=== 2) 它本体(整份，最多 120 行) ==='
F=$(grep -rln "^void ksu_set_app_profile\|^static void ksu_set_app_profile\|ksu_set_app_profile(struct app_profile" "$K" --include=*.c | head -1)
echo "文件=$F"
awk '/ksu_set_app_profile\(struct app_profile/,/^}/' "$F" | head -110
echo '=== 3) ksu_persistent_allow_list 本体 ==='
awk '/ksu_persistent_allow_list\(/,/^}/' "$K/policy/allowlist.c" | head -40
echo '=== 4) KSU_APP_PROFILE_VER 与 version 分支 ==='
grep -rn "KSU_APP_PROFILE_VER" "$K" ../uapi 2>/dev/null | head -6
echo END
