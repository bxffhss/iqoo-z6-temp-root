#!/bin/bash
# 只读审计 #2（路径已按 #1 的真实布局修正：/root/k/ksu/kernel/...）
K=/root/k/ksu/kernel
echo "=== A) ksu_guard_work：这是装载期登记的 work，谁排队、延时多少、干什么 ==="
grep -n "ksu_guard_work\|guard_work\|INIT_WORK\|schedule\|queue_" "$K/infra/dev_syms.c" | head -30
echo "--- 函数本体 ---"
awk '/ksu_guard_work_fn/,/^}/' "$K/infra/dev_syms.c" | head -60

echo; echo "=== B) allowlist.c 的 task_work_add(:493) 在哪个函数里、谁会调到它 ==="
sed -n '455,530p' "$K/policy/allowlist.c"

echo; echo "=== C) ksu_load_allow_list 本体(:527 起，读到 600) ==="
sed -n '527,600p' "$K/policy/allowlist.c"

echo; echo '=== D) 名单里【第二条】会不会去动 tracepoint/打标/cred ==='
grep -n "ksu_set_task_tracepoint_flag\|ksu_mark_all_process\|ksu_mark_running_process\|override_creds\|prepare_kernel_cred\|call_usermodehelper\|ksu_ensure_eventfd\|eventfd" "$K/policy/allowlist.c" "$K/policy/profile.c" "$K/core/init.c" 2>/dev/null | head -25

echo; echo "=== E) boot_event.c:29 第二次调 ksu_load_allow_list 的时机(post-fs-data? 定时器?) ==="
sed -n '1,60p' "$K/runtime/boot_event.c"

echo; echo '=== F) ksud_integration 里那个 stop_input_hook_work 与【第二条】有关系吗 ==='
grep -n "stop_input_hook\|input_hook" "$K/runtime/ksud_integration.c" | head -15
echo "END"
