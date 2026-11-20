#!/bin/bash
F=/root/k/ksu/kernel/policy/allowlist.c
echo '=== A) put_perm_data 与其释放回调：RCU 安全吗 ==='
grep -n "put_perm_data\|kref_put\|call_rcu\|synchronize_rcu\|rcu_assign\|kfree" "$F" | head -20
echo '--- put_perm_data 本体 + 回调本体 ---'
awk '/static void put_perm_data|void perm_data_release|static void .*release.*perm/,/^}/' "$F" | head -40
echo '=== B) ksu_set_app_profile 里"替换"那一支的完整片段(带行号) ==='
sed -n '200,240p' "$F" | cat -n | sed "s/^/   /"
echo '=== C) migrate_profile 本体 ==='
awk '/static void migrate_profile|void migrate_profile/,/^}/' "$F" | head -40
echo '=== D) profile_valid 本体(前 30 行) ==='
awk '/static bool profile_valid|bool profile_valid/,/^}/' "$F" | head -30
echo END
