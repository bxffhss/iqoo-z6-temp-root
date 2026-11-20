#!/bin/bash
F=/root/k/ksu/kernel/policy/allowlist.c
echo "字节=$(wc -c < $F) 行数=$(wc -l < $F) md5=$(md5sum $F | cut -d' ' -f1)"
echo "--- 逐个词单独 grep(不用转义竖线) ---"
for w in ksu_mark_allow_uid allowlist_save_data allowlist_find_entry eventfd ksu_event_queue override_creds; do
  echo "[$w] $(grep -c -- "$w" $F)"
done
echo "--- 定义在哪 ---"
grep -rn "void ksu_mark_allow_uid" /root/k/ksu/kernel | head -3
grep -rn "bool allowlist_save_data" /root/k/ksu/kernel | head -3
echo "--- ksu_mark_all_uid 的本体 ---"
grep -rn -A12 "void ksu_mark_all_uid" /root/k/ksu/kernel/policy/allowlist.c | head -20
