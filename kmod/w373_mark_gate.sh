#!/bin/bash
K=/root/k/ksu/kernel
echo '=== 1) 谁调 ksu_mark_running_process / ksu_mark_all_process ==='
grep -rn "ksu_mark_running_process\|ksu_mark_all_process\|ksu_unmark_all_process" "$K" --include=*.c --include=*.h | head -20
echo '=== 2) ksu_mass_mark 这个参数到底闸住谁 ==='
grep -rn "ksu_mass_mark" "$K" --include=*.c --include=*.h | head -12
echo '=== 3) 打行 "tp_marker: mark process" 的那个函数全文 ==='
F=$(grep -rl "tp_marker: mark process" "$K" --include=*.c | head -1); echo "文件=[$F]"
[ -n "$F" ] && awk '/void ksu_mark_running_process_locked/,/^}$/' "$F" | head -50
echo '=== 4) 它前面的早退闸到底在哪一层 ==='
[ -n "$F" ] && grep -n "mass_mark\|return" "$F" | head -20
echo END
