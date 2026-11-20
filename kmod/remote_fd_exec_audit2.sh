#!/usr/bin/env bash
set -u
# 只读审计第二条：改道(execve 那条)到底做了什么 —— 决定"执法态 app 侧 su"要不要事先给它装 fd。
K=/root/k/ksu/kernel
echo "=== 1) 改道字符串在哪匹配、匹配后做什么 ==="
grep -rn "system/bin/su\|ksu_ksud_path\|redirect" $K --include=*.c | head -24
echo "=== 2) exec/tracepoint 那个处理函数的函数体(找 install_fd / allow 判定) ==="
for f in $(grep -rl "ksu_ksud_path" $K --include=*.c); do echo "--- FILE $f"; awk '/^[a-zA-Z_].*\(/,/^}/' $f | grep -n "ksu_install_fd\|ksu_is_allow_uid\|is_uid_manager\|change_fd\|filp\|install" | head -12; done
echo "=== 3) 名单判定函数(哪个 uid 算放行) ==="
grep -rn "ksu_is_allow_uid_for_current" $K --include=*.c | head -8
echo "=== 4) supercall 里"给我 fd"那个动词的前置条件(要不要 allowlist) ==="
sed -n '95,130p' $K/supercall/supercall.c
grep -n "allowed_for_su\|perm_check\|always_allow" $K/supercall/dispatch.c | head -14
echo "FD_EXEC_AUDIT2_DONE"
