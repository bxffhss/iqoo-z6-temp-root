#!/bin/bash
# 只读审计 #3：上一跑的 stdout 被 ~8KiB 截了(而且 JSON 里 stdout_truncated 说是 false) ⇒ 这次只要 D/E/F 三段
K=/root/k/ksu/kernel
echo '=== D) 名单里【第二条】会不会去动 tracepoint/打标/cred/写盘 ==='
grep -n "ksu_mark_allow_uid\|allowlist_save_data\|eventfd\|ksu_event_queue\|override_creds\|call_usermodehelper\|prepare_kernel_cred" "$K/policy/allowlist.c" | head -18
echo '--- ksu_mark_allow_uid 本体 ---'
awk '/^void ksu_mark_allow_uid/,/^}/' "$K/policy/allowlist.c" | head -25
echo '--- allowlist_save_data 本体(前 40 行) ---'
awk '/^bool allowlist_save_data/,/^}/' "$K/policy/allowlist.c" | head -40

echo; echo '=== E) boot_event.c:29 那次第二遍 load 的触发形状 ==='
sed -n '1,70p' "$K/runtime/boot_event.c"

echo; echo '=== F) kboots 里那个 workqueue 会不会延时跑 ---'
grep -n "queue_delayed_work\|msecs_to_jiffies\|round_jiffies\|schedule_delayed_work" "$K" -r --include=*.c | head -15
echo "END"
